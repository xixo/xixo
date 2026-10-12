class Resource
  class Machine < Resource
    class Refusal < Resource::Failed; end

    MOST_CHUNKED = 256.kilobytes
    QUIET_AFTER = 3.minutes
    ANSWERED_WITHIN = 30.seconds
    READ_STALLS_AFTER = 60.seconds
    POLLED_EVERY = 0.05
    MOST_FOLDERS = 64
    MOST_SERVICES = 16
    MOST_DISKS = 32
    MOST_TEXT = 255
    MOST_WARNINGS = 16
    MOST_WARNING = 500
    MOST_PATH = 4096
    TAILNET = [ IPAddr.new("100.64.0.0/10"), IPAddr.new("fd7a:115c:a1e0::/48") ].freeze
    MOST_RESULT = 4.megabytes
    SERVICE_KINDS = %w[ollama lmstudio].freeze
    PUT_AWAY_TRIES = 3
    EXTRACTORS = %w[pdf image media doc epub xlsx calendar pkpass email contact data text fallback].freeze
    LOCAL = "local".freeze
    MINTED = "minted_at".freeze

    include Tools

    serves :transport

    before_validation(on: :create) { operated_by!(Current.grant) }

    validate :shared_by_everyone
    validate :host_key_is_a_fingerprint
    validate :host_key_given, if: -> { credentials.to_h["private_key"].present? }

    after_commit :install_later, on: %i[create update], if: :key_given?
    after_commit :hang_up, on: %i[update destroy], if: -> { put_away_now? || client_replaced? }

    class << self
      def attaching
        {
          label: "A Linux machine xixo sets up",
          blurb: "xixo signs in to the machine once over SSH, installs xixo link, and links it up. The key is " \
                 "used for that one install and then dropped. From then on xixo link on the machine dials xixo, " \
                 "shares the folders listed here, and reads the files in them on the machine.",
          names: "A name for the machine",
          fields: [
            field("host", "Address", required: true, placeholder: "100.64.0.5",
                  help: "Where xixo reaches its SSH server. Through a tailnet, its address on the tailnet."),
            field("port", "SSH port", kind: "integer", value: "22"),
            field("user", "SSH user", required: true, placeholder: "jon",
                  help: "xixo link runs as this user and reads only what it can read. The user needs sudo " \
                        "without a password to install it."),
            field("private_key", "SSH private key", kind: "text", secret: true,
                  help: "Used once to install xixo link and then dropped, whether the install worked or not. " \
                        "Paste it again to install again."),
            field("host_key", "Host key", placeholder: "SHA256:…",
                  help: "The SHA256 fingerprint that ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub prints on " \
                        "the machine. Needed unless the machine is reached through a tailnet, which vouches for " \
                        "its address. Left empty there, the key seen on the first install is kept, and every " \
                        "later install must meet the same one."),
            field("folders", "Folders it shares", kind: "lines", placeholder: "/srv/media",
                  help: "Absolute paths, one per line. End a line with :rw for a folder xixo may also write " \
                        "into. xixo link reads nothing outside them, and only an install or the machine's own " \
                        "config changes them."),
            field("programs", "Extract on the machine", kind: "boolean", value: "true",
                  help: "Installs the programs that read PDFs, office documents, images, audio, and video with " \
                        "apt on Debian or Ubuntu, so only text leaves the machine. Left off, the machine reads " \
                        "only plain text, data, calendars, contacts, email, books, and spreadsheets."),
            field("lend", "Send files this machine can't read to the server", kind: "boolean", value: "false",
                  help: "A file this machine has no program for goes to xixo link beside the server. Left off, " \
                        "such a file is not read, and nothing on this machine leaves it but text."),
            field("keep_tools", "Keep write and models on a reinstall", kind: "boolean", value: "false",
                  help: "A reinstall keeps browse, search, read, and extract from the config already on the " \
                        "machine. Turned on, it keeps write and models too, which let xixo write into the " \
                        "machine's folders and ask its model server."),
            field("operators", "Who operates it", kind: "lines",
                  help: "The masks subjects, one per line, whose clients may browse its folders, read its files' " \
                        "bytes, write into them, run its extractors, and ask its model server. The administrator " \
                        "who attaches or links the machine is listed on their own. Anyone else reaches only what " \
                        "xixo drew out of its files.")
          ]
        }
      end

      def command_schema
        { health: {}, discover: {} }.merge(tools_schema)
      end

      def command_help
        tools_help
      end

      def routable?
        true
      end

      def enrolled(client_id)
        return nil if client_id.blank?

        active.find_by("resources.details ->> 'client_id' = ?", client_id.to_s)
      end

      def carried_for!(resource, grant)
        return if grant&.administers? || !resource.via.is_a?(Machine)

        raise Resource::Refused, "only an administrator reaches a folder through a machine running xixo link. " \
                                 "#{Grant::ADMINISTERING}"
      end

      def local
        active.find_by("resources.details ->> 'local' = 'true'")
      end

      def local!
        find_by(key: LOCAL) || create!(key: LOCAL, name: "This server", details: { "local" => true })
      end

      def adopted_by!(grant)
        return unless grant&.administers? && grant.speaks_for.present?

        where(key: LOCAL).where("NOT (resources.details ? 'operators')").update_all(
          [ "details = details || jsonb_build_object('operators', jsonb_build_array(?::text))", grant.speaks_for ]
        )
      end

      def binaries
        Pathname.new(ENV.fetch("XIXO_LINK_DIR", "/opt/xixo-link"))
      end
    end

    def machine
      details.to_h["machine"].to_h
    end

    def client_id
      details.to_h["client_id"]
    end

    def host_key
      details.to_h["host_key"].to_s.strip.presence
    end

    def on_tailnet?(address)
      via.is_a?(Tailnet) && TAILNET.any? { |range| range.include?(IPAddr.new(address.to_s)) }
    rescue IPAddr::Error
      false
    end

    def offered_folders
      Array(machine["folders"])
    end

    def writable_folders
      Array(machine["writable"]) & offered_folders
    end

    def heard_from?
      machine.key?("folders")
    end

    def extractors
      Array(machine["extractors"])
    end

    def warnings
      Array(machine["warnings"]).grep(String)
    end

    def extracts?(kind)
      extractors.include?(kind.to_s)
    end

    def local?
      details.to_h["local"] == true
    end

    def programs?
      details.to_h["programs"] != false
    end

    def lends?
      details.to_h["lend"] == true
    end

    def keeps_tools?
      details.to_h["keep_tools"] == true
    end

    def seen_at
      Time.iso8601(machine["seen_at"].to_s)
    rescue ArgumentError
      nil
    end

    def connected?
      machine["connected"] == true && seen_at.present? && seen_at > QUIET_AFTER.ago
    end

    def self_linked?
      !local? && details.to_h["host"].blank?
    end

    def linking?
      Linking.waiting?(self)
    end

    def link_expires_at
      Linking.expires_at(self)
    end

    def extracts_for_others
      held = machine["extracts_for_others"]
      held if [ true, false ].include?(held)
    end

    def announce!
      XixoSchema.subscriptions.trigger(:machine_changed, { id: id.to_s }, Resource.find(id), scope: tenant_id)
      XixoSchema.subscriptions.trigger(:machine_changed, {}, Resource.find(id), scope: tenant_id)
    rescue StandardError => e
      Rails.logger.warn "machine #{id} could not announce: #{e.message}"
    end

    def installing?
      Run.open.exists?(resource_id: id, kind: "install")
    end

    def check!
      reload unless new_record? || changed?
      return true if installing? || connected?
      raise Resource::Failed, "#{key}: xixo link beside the server has not enrolled yet" if client_id.blank? && local?
      raise Resource::Failed, "#{key}: waiting for the machine to link up" if client_id.blank? && linking?
      raise Resource::Failed, "#{key}: the machine has not linked up yet. Get a fresh code to link it" if client_id.blank? && self_linked?
      raise Resource::Failed, "#{key}: xixo link is not installed yet. Paste an SSH key to install it" if client_id.blank?
      raise Resource::Failed, "#{key}: xixo link has never connected" if seen_at.nil?

      raise Resource::Failed, "#{key}: xixo link was last heard from #{seen_at.utc.iso8601}"
    end

    def carries?(resource)
      resource.is_a?(Filesystem)
    end

    def reach!(_target)
      raise Resource::Refused, "#{key} reaches only the folders it shares"
    end

    def covers
      []
    end

    def offline_peer(_host)
      return nil if connected?

      { "host_name" => machine["hostname"].presence || key, "last_seen" => seen_at&.utc&.iso8601 }
    end

    def discovered(services: false)
      offered_folders.map do |path|
        {
          "host_name" => File.basename(path).downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-").presence,
          "dns_name" => machine["hostname"],
          "addresses" => [],
          "online" => connected?,
          "last_seen" => seen_at&.utc&.iso8601,
          "services" => [ { "name" => "folder", "port" => 0, "type" => Filesystem.sti_name, "address" => path } ]
        }
      end
    end

    def command_health
      ask("health")
    end

    def command_discover
      { "transport" => key, "nodes" => discovered }
    end

    def ask(verb, args = {}, within: ANSWERED_WITHIN)
      exchanged(verb, args, within: within, &:result)
    end

    def exchanged(verb, args = {}, within: ANSWERED_WITHIN)
      exchange = asked(verb, args)

      yield Answer.new(self, exchange, awaited(exchange, verb, within))
    ensure
      LinkExchange.apart { LinkExchange.where(id: exchange.id).delete_all } if exchange
    end

    def read(folder, path, within: ANSWERED_WITHIN)
      exchanged("read", { "folder" => folder, "path" => path }, within: within) do |answer|
        Reading.new(self, answer.exchange, size: answer.result.to_h["size"]).file
      end
    end

    def glimpse(folder, path, limit:, within: ANSWERED_WITHIN)
      exchanged("read", { "folder" => folder, "path" => path, "limit" => limit }, within: within) do |answer|
        held = answer.result.to_h
        file = Reading.new(self, answer.exchange, size: held["size"]).file

        begin
          [ file.read(limit).to_s, held["total"].is_a?(Integer) ? held["total"] : held["size"] ]
        ensure
          file.close!
        end
      end
    end

    def upload(io)
      raise Resource::Offline, "#{key}: xixo link is not connected" unless connected?

      LinkExchange.apart { staged(io) }
    end

    def forget(request)
      LinkExchange.apart { LinkExchange.where(resource_id: id, request: request.to_s).delete_all }
    end

    def waiting
      sleep POLLED_EVERY
    end

    def greeted!(said, session:)
      merge_machine!(Hello.from(said).merge("session" => session, "connected" => true, "seen_at" => now_stamp))
      update_columns(offline_host: nil, offline_last_seen_at: nil, checked_at: Time.current, check_error: nil)
      restate_folders!
      announce!
    end

    def restate_folders!
      Filesystem.where(via_id: id).find_each do |folder|
        held = folder.served
        folder.update_columns(serving: held) unless folder.serving == held
      end
    end

    def heard!(said)
      merge_machine!("health" => Health.from(said), "warnings" => Hello.warnings(said.to_h["warnings"]), "seen_at" => now_stamp)
      update_columns(checked_at: Time.current, check_error: nil) if check_error.present?
    end

    def parted!(session:)
      Resource.where(id: id)
              .where("resources.details -> 'machine' ->> 'session' = ?", session.to_s)
              .update_all([ <<~SQL.squish, now_stamp, machine["hostname"].presence || key, Time.current ])
                details = jsonb_set(details, '{machine}', (details -> 'machine') || jsonb_build_object('connected', false, 'seen_at', ?::text)),
                offline_host = ?, offline_last_seen_at = ?
              SQL
      announce!
    end

    def bound!(client_id, revoker: Enrollment.method(:revoke))
      if self.client_id == client_id
        update!(details: details.to_h.except(Linking::KEY)) if details.to_h.key?(Linking::KEY)
        return
      end

      revoker.call(tenant, self.client_id) if self.client_id.present?
      self.details = details.to_h.merge("client_id" => client_id).except("machine", MINTED, Linking::KEY)
      self.check_error = nil
      self.checked_at = nil
      save!
      announce!
    end

    def enrolled!(client_id:, host_key:, installed: nil, revoker: Enrollment.method(:revoke))
      put_away = transaction do
        held = Machine.lock.find(id)
        next true if held.archived_at.present?

        held.details = held.details.to_h.merge(
          { "client_id" => client_id, "host_key" => host_key,
            "installed" => installed&.merge("at" => now_stamp)&.compact }.compact
        )
        held.save!
        false
      end
      reload

      return unless put_away

      revoker.call(tenant, client_id)
      forgotten!(client_id)
      raise Resource::Failed, "#{key} was put away while xixo link installed, so masks unenrolled its new client #{client_id}"
    end

    def unenroll!(revoker: Enrollment.method(:revoke))
      return if client_id.blank?

      revoker.call(tenant, client_id)
      self.details = unenrolled_details
      save!
    end

    def put_away(revoker: Enrollment.method(:revoke))
      self.archived_at = Time.current
      return false unless valid?

      restore_attributes([ :archived_at ])

      PUT_AWAY_TRIES.times do
        client = Machine.find(id).client_id
        revoker.call(tenant, client) if client.present?

        done = transaction do
          held = Machine.lock.find(id)
          next nil unless held.client_id == client

          held.archived_at = Time.current
          held.details = held.unenrolled_details if client.present?
          held.credentials = held.credentials.to_h.except("private_key")
          held.save
        end
        next if done.nil?

        reload
        return done
      end

      errors.add(:base, "#{key} enrolled again while it was being put away. Try again")
      false
    rescue Resource::Failed => e
      errors.add(:base, "#{e.message}, so #{key} stays attached and xixo link on it keeps signing in. Try again once masks answers")
      false
    end

    def forgotten!(client)
      transaction do
        held = Machine.lock.find(id)
        next unless held.client_id == client

        held.details = held.unenrolled_details
        held.save!
      end
      reload
    end

    def unenrolled_details
      details.to_h.except("client_id").merge("unenrolled" => { "client_id" => client_id, "at" => now_stamp })
    end

    def forget_key!
      return if credentials.to_h["private_key"].blank?

      self.credentials = credentials.to_h.except("private_key")
      save!
    end

    def install_later
      run = Run.start!(kind: "install", resource: self)
      InstallLinkJob.perform_later(id, run.id)
    end

    private

      def shared_by_everyone
        errors.add(:owner_subject, "cannot be set on a machine, which an administrator attaches for everyone") if personal?
      end

      def host_key_is_a_fingerprint
        return if host_key.nil? || host_key.match?(Installer::FINGERPRINT)

        errors.add(:host_key, "must be a SHA256 fingerprint such as ssh-keygen -lf prints, starting SHA256:")
      end

      def host_key_given
        return if host_key.present? || via.is_a?(Tailnet)

        errors.add(:host_key, "is needed for a machine reached outside a tailnet. Run ssh-keygen -lf " \
                              "/etc/ssh/ssh_host_ed25519_key.pub on the machine and paste the SHA256 fingerprint")
      end

      def put_away_now?
        destroyed? || (saved_change_to_archived_at? && archived_at.present?)
      end

      def client_replaced?
        before = details_before_last_save.to_h["client_id"]

        before.present? && before != client_id
      end

      def hang_up
        clients = [ details_before_last_save.to_h["client_id"] ]
        clients << client_id if put_away_now?

        clients.compact.uniq.each do |client|
          ActionCable.server.remote_connections.where(tenant: tenant, grant: nil, machine: self, client_id: client)
                     .disconnect(reconnect: false)
        end
      end

      def key_given?
        saved_change_to_credentials? && credentials.to_h["private_key"].present?
      end

      def asked(verb, args)
        raise Resource::Offline, "#{key}: xixo link is not connected" unless connected?

        exchange = LinkExchange.apart do
          raise Resource::Failed, "#{key}: xixo link already has #{LinkExchange::MOST_OPEN} questions open" if LinkExchange.crowded?(self)

          LinkExchange.create!(resource_id: id, request: SecureRandom.uuid, verb: verb)
        end
        LinkChannel.broadcast_to(self, { "request" => exchange.request, "verb" => verb, "args" => args.presence || {} })
        exchange
      end

      def staged(io)
        raise Resource::Failed, "#{key}: xixo link already has #{LinkExchange::MOST_OPEN} questions open" if LinkExchange.crowded?(self)

        exchange = LinkExchange.create!(resource_id: id, request: SecureRandom.uuid, verb: LinkExchange::UPLOAD)
        size = 0

        (0..).each do |seq|
          part = io.read(MOST_CHUNKED)
          break if part.nil?

          size += part.bytesize
          raise Resource::Failed, "#{key}: an upload is larger than #{LinkExchange::MOST_RECEIVED} bytes" if size > LinkExchange::MOST_RECEIVED

          exchange.chunks.create!(seq: seq, bytes: part)
        end

        exchange.update_columns(received: size)
        { "upload" => exchange.request, "size" => size }
      rescue StandardError
        LinkExchange.where(id: exchange.id).delete_all if exchange
        raise
      end

      def awaited(exchange, verb, within)
        LinkExchange.apart { waited(exchange, verb, within) }
      end

      def waited(exchange, verb, within)
        deadline = within.from_now

        loop do
          held = LinkExchange.uncached { LinkExchange.find(exchange.id) }
          return held.result if held.answered?
          raise Refusal, "#{key}: xixo link said #{held.error}" if held.refused?

          if Time.current > deadline
            held.refuse!("no answer in #{within.inspect}")
            raise Resource::Failed, "#{key}: xixo link did not answer #{verb} in #{within.inspect}"
          end

          waiting
        end
      end

      def merge_machine!(held)
        Resource.where(id: id).update_all([ <<~SQL.squish, held.to_json ])
          details = jsonb_set(details, '{machine}', COALESCE(details -> 'machine', '{}'::jsonb) || ?::jsonb)
        SQL
      end

      def now_stamp
        Time.current.utc.iso8601
      end
  end
end
