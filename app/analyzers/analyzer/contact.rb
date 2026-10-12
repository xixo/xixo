module Analyzer
  class Contact < Base
    def self.handles?(feed)
      feed.mime == "text/vcard"
    end
  end
end
