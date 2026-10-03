require "nokogiri"

class Resource
  class Rss < Resource
    include PublicFetch

    class Gone < Resource::Failed; end

    PAGE = 200
    MAX_TEXT = 100_000

    Entry = Data.define(:id, :title, :link, :published_at, :content)

    def self.notices_what_is_gone?
      false
    end

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "A feed",
        blurb: "An RSS or Atom feed. Each entry becomes an item.",
        names: "A name for it",
        fields: [
          field("url", "Feed URL", required: true, placeholder: "https://example.com/feed.xml")
        ]
      }
    end

    def self.command_schema
      {
        list: { limit: "integer?" },
        get: { id: "string" }
      }
    end

    def url
      details.fetch("url")
    end

    def check!
      raise Resource::Failed, "#{key}: #{url} served no entries" if entries.empty?

      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      found = entries.drop_while { |entry| cursor.present? && entry.id != cursor }
      found = found.drop(1) if cursor.present? && found.any?
      found = entries if cursor.present? && found.empty?

      found.each_slice(PAGE) { |batch| yield batch, batch.last.id }
    end

    def locator_for(entry)
      {
        "id" => entry.id, "link" => entry.link, "published_at" => entry.published_at,
        "digest" => Digest::SHA256.hexdigest([ entry.title, entry.link, entry.content ].join("\0"))[0, 32]
      }
    end

    def locator_key_for(entry)
      entry.id
    end

    def version_for(locator)
      locator.to_h["digest"].presence || locator.to_h["published_at"].presence
    end

    def mime_for(_entry)
      MimeType::ENTRY
    end

    def title_for(entry)
      entry.title.presence || entry.link.presence || entry.id
    end

    def download(locator)
      wanted = locator.fetch("id")
      entry = entries.find { |candidate| candidate.id == wanted }

      if entry.nil?
        raise Gone, "#{key}: #{wanted} has scrolled out of #{url} — a feed only serves its window"
      end

      StringIO.new(entry.content.to_s)
    end

    def command_list(limit: nil)
      count = (limit || 50).to_i.clamp(1, 500)

      {
        "url" => url,
        "entries" => entries.first(count).map { |entry| summary(entry) }
      }
    end

    def command_get(id:)
      entry = entries.find { |candidate| candidate.id == id }
      raise Gone, "#{key}: no entry #{id} in #{url}" if entry.nil?

      summary(entry).merge("text" => entry.content.to_s.truncate(MAX_TEXT))
    end

    private

      def summary(entry)
        {
          "id" => entry.id,
          "title" => entry.title,
          "link" => entry.link,
          "published_at" => entry.published_at
        }
      end

      def entries
        @entries ||= parse(fetch(url))
      end

      def parse(body)
        document = Nokogiri::XML(body) { |config| config.strict.nonet }

        items = document.css("item").presence || document.css("entry")
        items.filter_map { |item| entry_from(item) }
      rescue Nokogiri::XML::SyntaxError => e
        raise Resource::Failed, "#{key}: #{url} is not parseable XML — #{e.message.truncate(200)}"
      end

      def entry_from(item)
        link = text_of(item, "link").presence || item.at_css("link")&.[]("href")
        id = text_of(item, "guid").presence || text_of(item, "id").presence || link
        return nil if id.blank?

        Entry.new(
          id: id.strip,
          title: text_of(item, "title"),
          link: link&.strip,
          published_at: text_of(item, "pubDate").presence || text_of(item, "published").presence ||
            text_of(item, "updated"),
          content: text_of(item, "encoded").presence || text_of(item, "content").presence ||
            text_of(item, "description").presence || text_of(item, "summary")
        )
      end

      def text_of(item, name)
        item.at_xpath("./*[local-name()='#{name}']")&.text&.strip
      end

      def fetch(target)
        over_http(target) { |uri| Net::HTTP::Get.new(uri, "User-Agent" => "uris") }.body.to_s
      end
  end
end
