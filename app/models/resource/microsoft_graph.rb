class Resource
  class MicrosoftGraph < Api
    include Delegated

    API = "https://graph.microsoft.com/v1.0".freeze
    DRIVE = "/me/drive".freeze
    MAX_DOWNLOAD = 512.megabytes
    ROOT = %r{\A/[^:]*:?/?}
    ITEM_ID = /\A[A-Za-z0-9!_-]{1,200}\z/

    def self.api
      API
    end

    def self.service
      "Microsoft Graph"
    end

    serves :integration

    def self.delegated_provider
      "microsoft"
    end

    def self.walks_changes?
      true
    end

    def self.attaching
      {
        label: "OneDrive",
        blurb: "Connected through masks with your Microsoft account. masks keeps the tokens and hands " \
               "uris a fresh one when it needs it, so no secret is ever typed into uris.",
        names: "A name for it",
        fields: [
          field("folder", "Only under this folder",
                help: "A path within the drive. Left empty, the whole drive is catalogued.",
                placeholder: "Documents/Invoices")
        ]
      }
    end

    def self.command_schema
      {
        list: { folder: "string?", limit: "integer?" },
        get: { id: "string" },
        keep: { id: "string" }
      }
    end

    def folder
      details["folder"].to_s.delete_prefix("/").chomp("/").presence
    end

    def check!
      who = api_get("/me")

      if who["id"].blank?
        raise Resource::Failed, "#{key}: masks released a token Microsoft would not accept"
      end

      drive = api_get(DRIVE)

      raise Resource::Unusable, "#{key}: #{who['userPrincipalName']} has no drive" if drive["id"].blank?

      true
    end

    # Delta rather than a walk of every folder: one flat enumeration the service pages for us,
    # and a cursor that is the next page's own URL, so a resumed sync asks for exactly what it
    # had not reached.
    def each_page(cursor: nil, prefix: nil, walk: nil)
      since = walk&.since.to_h["delta"]
      held = cursor.presence || since.presence || "#{DRIVE}/root/delta"

      loop do
        found = delta(held, walk)
        entries = Array(found["value"]).select { |entry| entry.is_a?(Hash) }
        entries.each { |entry| learn(entry) }

        walk&.gone(entries.reject { |entry| entry.key?("folder") || kept?(entry) }.pluck("id"))

        batch = entries.select { |entry| kept?(entry) && under?(entry, prefix) }
        held = found["@odata.nextLink"]
        walk&.reached({ "delta" => found["@odata.deltaLink"] }) if found["@odata.deltaLink"].present?

        yield batch, held if batch.any?

        break if held.blank?
      end
    end

    def object_for(id)
      entry = api_get(item(id))

      raise ArgumentError, "#{key}: #{id} is not a file" unless file?(entry)
      raise ArgumentError, "#{key}: #{id} is outside #{folder}" unless under?(entry, folder)

      entry
    end

    def locator_for(entry)
      {
        "id" => entry["id"],
        "name" => entry["name"],
        "path" => path_of(entry),
        "mime_type" => entry.dig("file", "mimeType"),
        "size" => entry["size"],
        "etag" => entry["cTag"].presence || entry["eTag"].presence || entry["lastModifiedDateTime"]
      }
    end

    def locator_key_for(entry)
      entry.is_a?(Hash) ? entry["id"].to_s : entry.to_s
    end

    def title_for(entry)
      entry["name"].presence || entry["id"].to_s
    end

    def mime_for(entry)
      MimeType.for_filename(entry["name"].to_s)
    end

    def download(locator)
      wanted = api_redirect("#{DRIVE}/items/#{locator.fetch('id')}/content")

      StringIO.new(pulled(wanted))
    end

    def command_list(folder: nil, limit: nil)
      wanted = folder.presence || self.folder
      path = wanted.present? ? "#{DRIVE}/root:/#{wanted}:/children" : "#{DRIVE}/root/children"
      found = api_get(path, "$top": (limit || PAGE).to_i.clamp(1, PAGE))

      { "folder" => wanted, "files" => Array(found["value"]).map { |entry| described(entry) } }
    end

    def command_keep(id:) = kept(id)

    def command_get(id:)
      described(api_get(item(id)))
    end

    private

      def item(id)
        raise ArgumentError, "#{key}: #{id.inspect} is not a OneDrive item id" unless id.to_s.match?(ITEM_ID)

        "#{DRIVE}/items/#{id}"
      end

      def delta(held, walk)
        api_get(held)
      rescue Api::Expired
        raise if walk.nil? || walk.full?

        walk.start_over!
        api_get("#{DRIVE}/root/delta")
      end

      def file?(entry)
        !entry.key?("deleted") && !entry.key?("folder") && entry.key?("file")
      end

      def kept?(entry)
        file?(entry) && under?(entry, folder)
      end

      def under?(entry, within)
        wanted = within.to_s.delete_prefix("/").chomp("/")

        wanted.blank? || path_of(entry).downcase.start_with?("#{wanted.downcase}/")
      end

      def learn(entry)
        id = entry["id"]
        return if id.blank?

        if entry.key?("deleted")
          folders.delete(id)
        elsif entry.key?("root")
          folders[id] = ""
        elsif entry.key?("folder")
          folders[id] = path_of(entry)
        end
      end

      def path_of(entry)
        parent = entry["parentReference"].to_h
        above = parent["path"].present? ? parent["path"].sub(ROOT, "") : folder_path(parent["id"])

        [ above.presence, entry["name"] ].compact.join("/").delete_prefix("/")
      end

      def folder_path(id)
        return nil if id.blank?

        folders.fetch(id) do
          found = api_get("#{DRIVE}/items/#{id}", "$select": "id,name,parentReference,root")
          folders[id] = found.key?("root") ? "" : path_of(found)
        end
      end

      def folders
        @folders ||= {}
      end

      def described(entry)
        {
          "id" => entry["id"],
          "name" => entry["name"],
          "path" => path_of(entry),
          "size" => entry["size"],
          "mime_type" => entry.dig("file", "mimeType"),
          "modified_at" => entry["lastModifiedDateTime"],
          "folder" => entry.key?("folder")
        }
      end

      # The content endpoint answers with a redirect to a storage host that refuses the
      # Authorization header it was reached with, so the second leg is deliberately
      # unauthenticated — and, because its host arrives in a response rather than from us,
      # it is checked the way any other address a caller named would be.
      def api_redirect(path)
        uri = endpoint(path, {})

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(uri, headers))
        end

        return response["location"] if response.is_a?(Net::HTTPRedirection) && response["location"].present?
        raise Api::Gone, "#{key}: #{path} has no content" if response.is_a?(Net::HTTPNotFound)

        raise Resource::Failed, "#{key}: #{self.class.service} answered #{response.code} for content"
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching #{uri&.host}"
      end

      def pulled(target)
        Download.of(target, max_bytes: MAX_DOWNLOAD).bytes
      rescue Download::Blocked => e
        raise Resource::Unusable, "#{key}: #{e.message}"
      rescue Download::Failed => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end
  end
end
