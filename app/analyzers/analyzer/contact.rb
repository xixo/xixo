module Analyzer
  class Contact < Base
    MAX_CONTACTS = 500
    CELL_LIMIT = 1000

    SINGLE = %w[fn title org note bday nickname role].freeze
    REPEATED = %w[email tel url impp].freeze

    def self.handles?(feed)
      feed.mime == "text/vcard"
    end

    def analyze
      body = readable(reference.download.read)

      contacts = step(:contacts, digest: DECODED) { parse(body) }

      step(:text, digest: DECODED) { capped(flatten(contacts)) }
    end

    private

      def unfold(body)
        body.gsub(/\r?\n[ \t]/, "")
      end

      def unescape(value)
        value.gsub(/\\([nN,;\\])/) do
          escaped = Regexp.last_match(1)
          escaped.casecmp?("n") ? "\n" : escaped
        end
      end

      def parse(body)
        contacts = []
        current = nil

        unfold(body).each_line do |line|
          line = line.strip
          next if line.empty?

          case line.upcase
          when "BEGIN:VCARD" then current = {}
          when "END:VCARD"
            contacts << current if current.present?
            current = nil
            if contacts.size >= MAX_CONTACTS
              left_out("contacts", "only the first #{MAX_CONTACTS} contacts were read")
              break
            end
          else
            assign(current, line) if current
          end
        end

        contacts
      end

      def assign(contact, line)
        name, value = line.split(":", 2)
        return if value.blank?

        key = property(name)

        if SINGLE.include?(key)
          contact[key] ||= unescape(value).truncate(CELL_LIMIT)
        elsif REPEATED.include?(key)
          (contact[key] ||= []) << unescape(value).truncate(CELL_LIMIT)
        elsif key == "n"
          contact["name"] ||= structured(value)
        elsif key == "adr"
          (contact["adr"] ||= []) << structured(value)
        end
      end

      def property(name)
        name.to_s.split(";").first.to_s.split(".").last.to_s.downcase
      end

      def structured(value)
        value.split(/(?<!\\);/).map { |part| unescape(part).strip }.reject(&:empty?)
             .join(" ").truncate(CELL_LIMIT)
      end

      def flatten(contacts)
        contacts.map do |contact|
          [
            contact["fn"] || contact["name"],
            contact["org"], contact["title"],
            Array(contact["email"]).join(" "), Array(contact["tel"]).join(" "),
            Array(contact["adr"]).join(" "), contact["note"]
          ].compact_blank.join(" · ")
        end.join("\n")
      end
  end
end
