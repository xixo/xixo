module Analyzer
  class Pkpass < Base
    def self.handles?(feed)
      feed.mime == "application/vnd.apple.pkpass"
    end
  end
end
