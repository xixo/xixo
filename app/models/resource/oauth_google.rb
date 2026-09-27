class Resource
  class OauthGoogle < Api
    include Delegated

    API = "https://www.googleapis.com/drive/v3".freeze
    MAX_DOWNLOAD = 512.megabytes
    FIELDS = "id,name,mimeType,size,md5Checksum,modifiedTime,parents".freeze

    def self.api
      API
    end

    def self.service
      "Drive"
    end

    serves :integration

    def self.attaching
      {
        label: "Google Drive",
        blurb: "Connected through masks with your Google account. masks keeps the tokens and hands " \
               "uris a fresh one when it needs it, so no secret is ever typed into uris.",
        names: "A name for it",
        fields: []
      }
    end

    def self.delegated_provider
      "google"
    end

    def self.command_schema
      {
        list: { query: "string?", folder: "string?", page_token: "string?", limit: "integer?" },
        get: { id: "string" }
      }
    end

    def check!
      about = api_get("/about", fields: "user")

      raise Resource::Failed, "#{key}: masks released a token Drive would not accept" if about["user"].blank?

      true
    end

    def command_list(query: nil, folder: nil, page_token: nil, limit: nil)
      page = api_get(
        "/files",
        q: drive_query(query, folder),
        pageSize: [ limit&.to_i || PAGE, PAGE ].min,
        pageToken: page_token.presence,
        fields: "nextPageToken,files(#{FIELDS})",
        supportsAllDrives: true,
        includeItemsFromAllDrives: true
      )

      {
        "files" => Array(page["files"]).map { |file| describe(file) },
        "page_token" => page["nextPageToken"]
      }
    end

    def command_get(id:)
      file = api_get("/files/#{escaped_segment(id)}", fields: FIELDS, supportsAllDrives: true)
      within_query!(file)

      describe(file).merge(text_for(file))
    end

    def locator_for(file)
      {
        "id" => file["id"],
        "name" => file["name"],
        "mime_type" => file["mimeType"],
        "etag" => file["md5Checksum"].presence || file["modifiedTime"]
      }
    end

    def locator_key_for(file)
      file.is_a?(Hash) ? file["id"].to_s : file.to_s
    end

    def download(locator)
      StringIO.new(api_download(locator.fetch("id")))
    end

    private

      def describe(file)
        {
          "id" => file["id"],
          "name" => file["name"],
          "mime_type" => file["mimeType"],
          "size" => file["size"]&.to_i,
          "modified_at" => file["modifiedTime"]
        }
      end

      def text_for(file)
        return { "text" => nil, "note" => "a folder has no content" } if folder?(file)
        return { "text" => nil, "note" => "an editor document must be exported, not downloaded" } if native?(file)

        bytes = api_download(file["id"])
        text = bytes.dup.force_encoding(Encoding::UTF_8)

        return { "text" => text.truncate(MAX_TEXT) } if text.valid_encoding?

        { "text" => nil, "note" => "binary — export it or sync it into the catalog instead" }
      end

      def api_download(id)
        api_bytes("/files/#{escaped_segment(id)}", max_bytes: MAX_DOWNLOAD,
                                                     alt: "media", supportsAllDrives: true)
      end

      def folder?(file)
        file["mimeType"] == "application/vnd.google-apps.folder"
      end

      def native?(file)
        file["mimeType"].to_s.start_with?("application/vnd.google-apps.")
      end

      def within_query!(file)
        return if details["query"].blank?

        narrowed = [ drive_query(nil, file["parents"]&.first), "name = #{quoted(file['name'])}" ].join(" and ")
        found = api_get("/files", q: narrowed, fields: "files(id)", pageSize: PAGE,
                                  supportsAllDrives: true, includeItemsFromAllDrives: true)

        return if Array(found["files"]).any? { |held| held["id"] == file["id"] }

        raise ArgumentError, "#{key}: #{file['name']} is outside what it reads"
      end

      def quoted(value)
        "'#{value.to_s.gsub(/[\\']/) { |said| "\\#{said}" }}'"
      end

      def drive_query(query, folder)
        clauses = [ "trashed = false" ]
        clauses << "name contains #{quoted(query)}" if query.present?
        clauses << "#{quoted(folder)} in parents" if folder.present?
        clauses << "(#{details['query']})" if details["query"].present?

        clauses.join(" and ")
      end
  end
end
