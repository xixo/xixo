module Analyzer
  class Text < Base
    def self.handles?(feed)
      MimeType.text?(feed.mime)
    end
  end
end
