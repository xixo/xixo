module Analyzer
  class Pdf < Base
    def self.handles?(feed)
      feed.mime == "application/pdf"
    end
  end
end
