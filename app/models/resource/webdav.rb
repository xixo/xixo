require "nokogiri"
require "erb"

class Resource
  class Webdav < Resource
    include PublicFetch

    PAGE = 200

    Entry = Data.define(:path, :size, :etag, :modified_at, :content_type, :collection)

    class Propfind < Net::HTTPRequest
      METHOD = "PROPFIND".freeze
      REQUEST_HAS_BODY = true
      RESPONSE_HAS_BODY = true
    end

    class Mkcol < Net::HTTPRequest
      METHOD = "MKCOL".freeze
      REQUEST_HAS_BODY = false
      RESPONSE_HAS_BODY = true
    end

    PROPS = <<~XML.freeze
      <?xml version="1.0" encoding="utf-8"?>
      <d:propfind xmlns:d="DAV:"><d:prop>
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
        <d:getetag/><d:getcontenttype/>
      </d:prop></d:propfind>
    XML

    serves :storage
    accepts "*/*"

    def self.attaching
      {
        label: "WebDAV",
        blurb: "A WebDAV collection — Nextcloud, ownCloud, or anything else speaking it.",
        names: "A name for it",
        fields: [
          field("url", "Collection URL", required: true,
                placeholder: "https://cloud.example.com/remote.php/dav/files/you/"),
          field("prefix", "Prefix", help: "Left off, the whole collection is walked."),
          field("username", "Username", held: :credentials),
          field("password", "Password", secret: true)
        ]
      }
    end

    def self.command_schema
      {
        list: { prefix: "string?", limit: "integer?" },
        get: { key: "string" },
        keep: { key: "string" },
        put: { key: "string", body: "bytes" }
      }
    end

    def url
      details.fetch("url")
    end

    def base
      @base ||= url.end_with?("/") ? url : "#{url}/"
    end

    def check!
      children_of("")
      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      walk(prefix).drop_while { |entry| cursor.present? && !after?(entry.path, cursor) }
                  .each_slice(PAGE) { |batch| yield batch, batch.last.path }
    end

    def object_for(name)
      within_prefix(name)
      found = propfind(name, "0").first

      if found.nil? || found.collection || !wanted?(found)
        raise Resource::Failed, "#{key}: nothing it catalogues at #{name}"
      end

      within_prefix(found.path)

      found
    end

    def locator_for(entry)
      {
        "path" => entry.path,
        "etag" => entry.etag,
        "size" => entry.size,
        "modified_at" => entry.modified_at
      }
    end

    def locator_key_for(entry)
      entry.path
    end

    def download(locator)
      response = over_http(url_for(locator.fetch("path"))) { |uri| authorized(Net::HTTP::Get.new(uri)) }

      StringIO.new(response.body.to_s)
    end

    def upload(name, body)
      content = body.respond_to?(:read) ? body.read : body.to_s
      ancestors_of(name).each { |collection| mkcol!(collection) }

      response = over_http(url_for(name)) do |uri|
        authorized(Net::HTTP::Put.new(uri, "Content-Type" => "application/octet-stream")).tap do |put|
          put.body = content
        end
      end

      { "path" => name, "etag" => response["etag"]&.delete('"'), "size" => content.bytesize }
    end

    def command_list(prefix: nil, limit: nil)
      count = (limit || 1000).to_i.clamp(1, 5000)

      {
        "objects" => walk(prefix).first(count).map do |entry|
          { "key" => entry.path, "size" => entry.size, "last_modified" => entry.modified_at }
        end
      }
    end

    def command_get(key:)
      bytes = download(locator_for(object_for(key))).read

      glimpse(key, bytes, bytes.bytesize)
    end

    def command_keep(key:) = kept(key)

    def command_put(key:, body:)
      upload(key, body)
    end

    private

      def within_prefix(asked)
        under = details["prefix"].to_s.delete_prefix("/").chomp("/")
        held = asked.to_s.delete_prefix("/").chomp("/")
        return held.presence || under if under.blank? || held == under || held.start_with?("#{under}/")

        raise ArgumentError, "#{key}: #{asked} is outside #{under}"
      end

      def wanted?(_entry)
        true
      end

      def walk(prefix = nil)
        Enumerator.new { |yielder| descend(within_prefix(prefix).to_s, yielder) }.lazy
      end

      def after?(path, cursor)
        (path.to_s.split("/") <=> cursor.to_s.split("/")).to_i.positive?
      end

      def descend(path, yielder)
        children_of(path).sort_by { |entry| entry.path.split("/") }.each do |entry|
          if entry.collection
            descend(entry.path, yielder)
          elsif wanted?(entry)
            yielder.yield(entry)
          end
        end
      end

      def children_of(path)
        propfind(path, "1", under: path)
      end

      def propfind(path, depth, under: nil)
        response = over_http(url_for(path)) do |uri|
          authorized(Propfind.new(uri, "Depth" => depth, "Content-Type" => 'application/xml; charset="utf-8"'))
            .tap { |request| request.body = PROPS }
        end

        parse(response.body.to_s, under: under)
      end

      def parse(body, under:)
        document = Nokogiri::XML(body) { |config| config.strict.nonet }

        document.xpath("//*[local-name()='response']").filter_map { |node| entry_from(node, under) }
      rescue Nokogiri::XML::SyntaxError => e
        raise Resource::Failed, "#{key}: #{url} answered unparseable XML — #{e.message.truncate(200)}"
      end

      def entry_from(node, under)
        path = relative(text_at(node, "href"))
        return nil if path.blank? || path == under.to_s.chomp("/")

        Entry.new(
          path: path,
          size: text_at(node, "getcontentlength")&.to_i,
          etag: text_at(node, "getetag")&.delete('"'),
          modified_at: text_at(node, "getlastmodified"),
          content_type: text_at(node, "getcontenttype"),
          collection: node.at_xpath(".//*[local-name()='resourcetype']/*[local-name()='collection']").present?
        )
      end

      def text_at(node, name)
        node.at_xpath(".//*[local-name()='#{name}']")&.text&.strip.presence
      end

      def relative(href)
        return nil if href.blank?

        path = URI.decode_www_form_component(URI.parse(href).path.to_s)
        prefix = URI.parse(base).path

        return nil unless path.start_with?(prefix)

        path.delete_prefix(prefix).chomp("/")
      rescue URI::InvalidURIError
        nil
      end

      def url_for(path)
        URI.join(base, escaped_path(path)).to_s
      end

      def ancestors_of(name)
        parts = name.to_s.split("/")[0..-2].to_a

        parts.each_index.map { |index| parts[0..index].join("/") }
      end

      def mkcol!(path)
        return if path.blank?

        response = exchange(pinned!(url_for(path))) { |target| authorized(Mkcol.new(target)) }

        return if response.is_a?(Net::HTTPSuccess) || response.code == "405"

        raise Resource::Failed, "#{key}: creating #{path} answered #{response.code}"
      end

      def authorized(request)
        username = credentials["username"]
        request.basic_auth(username, credentials["password"]) if username.present?
        request
      end
  end
end
