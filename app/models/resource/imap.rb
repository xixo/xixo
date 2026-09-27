require "net/imap"
require "mail"

class Resource
  class Imap < Resource
    PAGE = 200
    LISTED = 50

    Message = Data.define(:uid, :uidvalidity, :mailbox, :subject, :from, :date, :size)

    class Pinned < Net::IMAP
      def initialize(host, address:, **options)
        @address = address
        super(host, **options)
      end

      private

        def tcp_socket(_host, port)
          Socket.tcp(@address, port, connect_timeout: open_timeout)
        end
    end

    def self.attaching
      {
        label: "A mailbox",
        blurb: "One IMAP mailbox. Messages are catalogued, and their attachments become items " \
               "of their own.",
        names: "A name for it",
        fields: [
          field("host", "Server", required: true, placeholder: "imap.example.com"),
          field("port", "Port", kind: "integer", help: "Left off, 993 with TLS and 143 without."),
          field("ssl", "Over TLS", kind: "boolean", value: "true"),
          field("mailbox", "Mailbox", value: "INBOX"),
          field("username", "Username", required: true, held: :credentials),
          field("password", "Password", required: true, secret: true)
        ]
      }
    end

    def self.command_schema
      {
        list: { limit: "integer?" },
        get: { uid: "integer" },
        search: { query: "string" }
      }
    end

    def mailbox
      details.fetch("mailbox", "INBOX")
    end

    def host
      details.fetch("host")
    end

    def port
      details.fetch("port", ssl? ? 993 : 143).to_i
    end

    def ssl?
      details.fetch("ssl", true)
    end

    def self.walks_changes?
      true
    end

    def check!
      connect { |imap| examine(imap) }
      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      cursor ||= resumed_from(walk)

      loop do
        page, following = connect { |imap| page_after(imap, cursor) }

        break if page.empty?

        cursor = following
        walk&.reached({ "uidvalidity" => page.last.uidvalidity, "uid" => page.map(&:uid).max })
        yield page, cursor

        break if page.size < PAGE
      end
    end

    def locator_for(message)
      {
        "mailbox" => message.mailbox,
        "uidvalidity" => message.uidvalidity,
        "uid" => message.uid
      }
    end

    def locator_key_for(message)
      [ message.mailbox, message.uidvalidity, message.uid ].join("/")
    end

    def mime_for(_message)
      "message/rfc822"
    end

    def title_for(message)
      message.subject.presence || "(no subject)"
    end

    def download(locator)
      name = locator.fetch("mailbox")
      uid = Integer(locator.fetch("uid"))

      connect do |imap|
        validity = examine(imap, name)
        expected = Integer(locator.fetch("uidvalidity"))

        unless validity == expected
          raise Resource::Failed,
                "#{key}: #{name} was renumbered (UIDVALIDITY #{expected} is now #{validity}), " \
                "so UID #{uid} no longer names the message it named"
        end

        StringIO.new(source_of(imap, uid, name))
      end
    end

    def command_list(limit: nil)
      name = mailbox
      count = (limit || LISTED).to_i.clamp(1, 500)

      connect do |imap|
        validity = examine(imap, name)
        uids = imap.uid_search([ "ALL" ]).last(count)

        {
          "mailbox" => name,
          "uidvalidity" => validity,
          "messages" => summaries(imap, uids, validity, name)
        }
      end
    end

    def command_get(uid:)
      name = mailbox
      wanted = Integer(uid)

      connect do |imap|
        validity = examine(imap, name)
        data = imap.uid_fetch(wanted, [ "RFC822.SIZE", "BODY.PEEK[]<0.#{GLIMPSE_BYTES}>" ]).to_a.first
        raise Resource::Failed, "#{key}: no message at UID #{wanted} in #{name}" if data.nil?

        head = data.attr.find { |attribute, _| attribute.start_with?("BODY[]") }&.last

        {
          "mailbox" => name,
          "uidvalidity" => validity,
          "uid" => wanted,
          "size" => data.attr["RFC822.SIZE"],
          "text" => head.to_s.dup.force_encoding(Encoding::UTF_8).scrub.truncate(MAX_TEXT)
        }
      end
    end

    def command_search(query:)
      name = mailbox

      connect do |imap|
        validity = examine(imap, name)
        uids = imap.uid_search([ "TEXT", query.to_s ]).last(LISTED)

        {
          "mailbox" => name,
          "uidvalidity" => validity,
          "query" => query,
          "messages" => summaries(imap, uids, validity, name)
        }
      end
    end

    private

      def connect
        imap = Pinned.new(host, address: address, port: port, ssl: ssl_options)
        imap.login(credentials.fetch("username"), credentials.fetch("password"))
        yield imap
      rescue Net::IMAP::Error, OpenSSL::SSL::SSLError, SocketError, SystemCallError, IOError => e
        raise Resource::Failed, "#{key}: #{e.message}"
      ensure
        close(imap)
      end

      def address
        PublicAddress.address_for!(host)
      rescue PublicAddress::Blocked => e
        raise PublicFetch::Blocked, "#{key}: #{e.message}"
      rescue PublicAddress::Unresolvable => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end

      def ssl_options
        return false unless ssl?
        return true if details.fetch("verify_ssl", true)

        { verify_mode: OpenSSL::SSL::VERIFY_NONE }
      end

      def close(imap)
        return if imap.nil? || imap.disconnected?

        imap.logout
        imap.disconnect
      rescue StandardError
        nil
      end

      def examine(imap, name = mailbox)
        imap.examine(name)
        Integer(imap.responses("UIDVALIDITY", &:last))
      rescue TypeError, ArgumentError
        raise Resource::Failed, "#{key}: #{name} reported no UIDVALIDITY"
      end

      def resumed_from(walk)
        since = walk&.since.to_h
        return nil if since.blank?

        validity = connect { |imap| examine(imap) }
        return "#{validity}:#{since['uid'].to_i + 1}" if since["uidvalidity"].to_i == validity

        walk.start_over!
        nil
      end

      def page_after(imap, cursor)
        validity = examine(imap)
        from = resume_at(cursor, validity)
        uids = imap.uid_search([ "UID", "#{from}:*" ]).select { |uid| uid >= from }.sort.first(PAGE)

        return [ [], cursor ] if uids.blank?

        [ messages_for(imap, uids, validity, mailbox), "#{validity}:#{uids.last + 1}" ]
      end

      def resume_at(cursor, validity)
        generation, uid = cursor.to_s.split(":")
        return 1 if uid.blank? || generation.to_i != validity

        uid.to_i
      end

      def messages_for(imap, uids, validity, name)
        return [] if uids.blank?

        imap.uid_fetch(uids, %w[UID ENVELOPE RFC822.SIZE]).to_a.map do |data|
          envelope = data.attr["ENVELOPE"]

          Message.new(
            uid: data.attr["UID"],
            uidvalidity: validity,
            mailbox: name,
            subject: decode(envelope&.subject),
            from: address_of(envelope&.from&.first),
            date: envelope&.date,
            size: data.attr["RFC822.SIZE"]
          )
        end
      end

      def summaries(imap, uids, validity, name)
        messages_for(imap, uids, validity, name).map do |message|
          {
            "uid" => message.uid,
            "subject" => message.subject,
            "from" => message.from,
            "date" => message.date,
            "size" => message.size
          }
        end
      end

      def source_of(imap, uid, name)
        data = imap.uid_fetch(uid, [ "BODY.PEEK[]" ]).to_a.first
        raise Resource::Failed, "#{key}: no message at UID #{uid} in #{name}" if data.nil?

        data.attr["BODY[]"].to_s
      end

      def decode(value)
        return nil if value.blank?

        Mail::Encodings.value_decode(value.to_s).presence
      rescue StandardError
        value.to_s.presence
      end

      def address_of(address)
        return nil if address.nil?

        mail = [ address.mailbox, address.host ].compact.join("@").presence
        name = decode(address.name)

        [ name, mail && (name ? "<#{mail}>" : mail) ].compact.join(" ").presence
      end
  end
end
