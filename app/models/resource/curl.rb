require "net/http"
require "nokogiri"

class Resource
  class Curl < Resource
    include PublicFetch

    MAX_TEXT = 20_000
    TEXTUAL = %r{\A(text/|application/(json|xml|xhtml\+xml|rss\+xml|atom\+xml|ld\+json))}
    NOISE = "script, style, noscript, template, svg, iframe, nav, footer, form".freeze
    BLOCKS = "br, p, div, li, tr, dt, dd, h1, h2, h3, h4, h5, h6, section, article, table, pre, blockquote".freeze
    INLINE = "td, th, a, span, b, strong, em, i, label".freeze
    HEADERS = {
      "User-Agent" => "uris",
      "Accept" => "text/html,application/xhtml+xml,application/json;q=0.9,text/*;q=0.8,*/*;q=0.1"
    }.freeze

    serves :fetch

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "Fetch a page",
        blurb: "Reads one address over HTTP, the way curl would, so an agent can read a page a " \
               "search turned up. Private and local addresses are refused, and nothing it reads " \
               "is kept unless something chooses to keep it.",
        names: "A name for it",
        fields: []
      }
    end

    def self.command_schema
      { get: { url: "string" } }
    end

    def check!
      true
    end

    def command_get(url:)
      response = over_http(url.to_s.strip) { |uri| Net::HTTP::Get.new(uri, HEADERS) }
      type = response["content-type"].to_s.split(";").first.to_s.strip.downcase
      body = response.body.to_s

      { url: url, status: response.code.to_i, content_type: type.presence, bytes: body.bytesize }
        .merge(read(body, type))
    end

    private

      def read(body, type)
        return { text: nil, note: "this is not text, so it was not read" } unless textual?(body, type)

        held = body.dup.force_encoding(Encoding::UTF_8).scrub
        return { text: held.strip.truncate(MAX_TEXT) } unless html?(held, type)

        page = Nokogiri::HTML(held)
        title = page.at("title")&.text&.squish.presence
        page.css(NOISE).remove

        { title: title, text: legible(page.at("body") || page).truncate(MAX_TEXT) }
      end

      def textual?(body, type)
        return type.match?(TEXTUAL) if type.present?

        !body.byteslice(0, 1024).to_s.include?("\x00")
      end

      def html?(body, type)
        type.include?("html") || (type.blank? && body.lstrip.start_with?("<"))
      end

      def legible(node)
        node.css(BLOCKS).each { |held| held.add_next_sibling("\n") }
        node.css(INLINE).each { |held| held.add_next_sibling(" ") }

        node.text.gsub(/[ \t\r\f]+/, " ").gsub(/\s*\n\s*/, "\n").gsub(/\n{3,}/, "\n\n").strip
      end
  end
end
