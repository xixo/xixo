module Analyzer
  class Doc < Base
    DOCS = %w[
      application/msword
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.oasis.opendocument.text
    ].freeze

    def self.handles?(feed)
      DOCS.include?(feed.mime)
    end
  end
end
