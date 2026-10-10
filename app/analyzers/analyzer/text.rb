module Analyzer
  class Text < Base
    def self.handles?(feed)
      MimeType.text?(feed.mime)
    end

    def analyze
      step(:text, digest: DECODED) { capped(readable(reference.download.read).strip) }
    end
  end
end
