module Analyzer
  class Text < Base
    def self.handles?(feed)
      MimeType.text?(feed.mime)
    end

    def analyze
      step(:text) { readable(reference.download.read).strip.truncate(MAX_TEXT) }
    end
  end
end
