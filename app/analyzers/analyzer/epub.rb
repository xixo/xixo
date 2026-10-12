module Analyzer
  class Epub < Base
    MIME = "application/epub+zip".freeze

    def self.handles?(feed)
      feed.mime == MIME
    end

    def summary_noun
      "book"
    end
  end
end
