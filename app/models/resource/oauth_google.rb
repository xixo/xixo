class Resource
  class OauthGoogle < Api
    include Delegated

    API = "https://www.googleapis.com/drive/v3".freeze
    MAX_DOWNLOAD = 512.megabytes
    FIELDS = "id,name,mimeType,size,md5Checksum,modifiedTime,parents".freeze
    FOLDER = "application/vnd.google-apps.folder".freeze
    MAX_EXPORT = 10.megabytes
    EXPORTS = {
      "application/vnd.google-apps.document" =>
        [ "application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx" ],
      "application/vnd.google-apps.spreadsheet" =>
        [ "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xlsx" ],
      "application/vnd.google-apps.presentation" => [ "application/pdf", ".pdf" ],
      "application/vnd.google-apps.drawing" => [ "image/png", ".png" ]
    }.freeze

    def self.walks_changes?
      true
    end

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
               "xixo a fresh one when it needs it, so no secret is ever typed into xixo. A sync " \
               "catalogues your files, with Docs, Sheets, Slides, and drawings read as Word, Excel, " \
               "PDF, and PNG files.",
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

    def each_page(cursor: nil, prefix: nil, walk: nil, &block)
      since = walk&.since.to_h["page_token"]
      return changed(cursor.presence || since, walk, &block) if since.present?

      walk&.reached(first: true) { { "page_token" => start_token } }
      listed(cursor.presence, &block)
    end

    def command_get(id:)
      file = object_for(id)

      describe(file).merge(text_for(file))
    end

    def object_for(id)
      file = api_get("/files/#{escaped_segment(id)}", fields: FIELDS, supportsAllDrives: true)
      return file if within_query?(file)

      raise ArgumentError, "#{key}: #{file['name']} is outside what it reads"
    end

    def locator_for(file)
      {
        "id" => file["id"],
        "name" => file["name"],
        "mime_type" => file["mimeType"],
        "export" => EXPORTS.dig(file["mimeType"], 0),
        "etag" => file["md5Checksum"].presence || file["modifiedTime"]
      }.compact
    end

    def title_for(file)
      name = file["name"].presence || file["id"].to_s
      extension = EXPORTS.dig(file["mimeType"], 1)
      extension && !name.downcase.end_with?(extension) ? "#{name}#{extension}" : name
    end

    def mime_for(file)
      EXPORTS.dig(file["mimeType"], 0) || file["mimeType"].presence || MimeType.for_filename(file["name"].to_s)
    end

    def locator_key_for(file)
      file.is_a?(Hash) ? file["id"].to_s : file.to_s
    end

    def download(locator)
      wanted = locator["export"]
      return StringIO.new(api_download(locator.fetch("id"))) if wanted.blank?

      StringIO.new(api_bytes("/files/#{escaped_segment(locator.fetch('id'))}/export",
                             max_bytes: MAX_EXPORT, mimeType: wanted))
    end

    private

      def paged(path, token, **params)
        loop do
          page = api_get(path, pageToken: token, pageSize: PAGE, supportsAllDrives: true,
                               includeItemsFromAllDrives: true, **params)
          token = page["nextPageToken"].presence

          yield page, token
          break if token.nil?
        end
      end

      def listed(token)
        paged("/files", token, q: "#{drive_query(nil, nil)} and mimeType != '#{FOLDER}'",
                               fields: "nextPageToken,files(#{FIELDS})") do |page, following|
          files = Array(page["files"]).select { |file| syncs?(file) }
          yield files, following if files.any?
        end
      end

      def changed(token, walk)
        fields = "nextPageToken,newStartPageToken,changes(fileId,removed,file(#{FIELDS},trashed))"

        paged("/changes", token, fields: fields) do |page, following|
          files, gone = Array(page["changes"]).partition do |change|
            !change["removed"] && !change.dig("file", "trashed") && syncs?(change["file"]) && within_query?(change["file"])
          end
          walk&.gone(gone.pluck("fileId"))
          walk&.reached({ "page_token" => page["newStartPageToken"] }) if page["newStartPageToken"].present?

          yield files.pluck("file"), following if files.any?
        end
      end

      def start_token
        api_get("/changes/startPageToken", supportsAllDrives: true)["startPageToken"]
      end

      def syncs?(file)
        !native?(file) || EXPORTS.key?(file["mimeType"])
      end

      def within_query?(file)
        return true if details["query"].blank?

        narrowed = [ drive_query(nil, file["parents"]&.first), "name = #{quoted(file['name'])}" ].join(" and ")
        found = api_get("/files", q: narrowed, fields: "files(id)", pageSize: PAGE,
                                  supportsAllDrives: true, includeItemsFromAllDrives: true)

        Array(found["files"]).any? { |held| held["id"] == file["id"] }
      rescue Resource::Failed
        false
      end

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
        file["mimeType"] == FOLDER
      end

      def native?(file)
        file["mimeType"].to_s.start_with?("application/vnd.google-apps.")
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
