module Analyzer
  class Entry < Base
    def self.handles?(feed)
      feed.mime == MimeType::ENTRY
    end

    def self.carries_bytes?
      false
    end

    def analyze
      step(:entry) { entry_of(reference) }
      step(:text) { body_of(reference).truncate(MAX_TEXT) }
    end

    private

      def entry_of(reference)
        reference.locator.slice("link", "published_at").compact
      end

      def body_of(reference)
        content = readable(reference.download.read)

        [ reference.feed.title, Markup.strip(content) ].compact_blank.join("\n\n").strip
      end
  end
end
