module Analyzer
  class Data < Base
    def self.handles?(feed)
      %w[application/json application/xml text/csv text/tab-separated-values].include?(feed.mime)
    end
  end
end
