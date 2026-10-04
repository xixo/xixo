require "csv"

module Analyzer
  class Data < Base
    def self.handles?(feed)
      %w[application/json application/xml text/csv text/tab-separated-values].include?(feed.mime)
    end

    def analyze
      body = reference.download.read.force_encoding("UTF-8").scrub

      step(:shape) { shape_of(body) }
      step(:tables, digest: Tables::ROWS.to_s) { tables_of(body) } if separator
      step(:text) { body.strip.truncate(MAX_TEXT) }
    end

    def separator
      { ".csv" => ",", ".tsv" => "\t" }[File.extname(reference.locator_key.to_s).downcase]
    end

    private

      def tables_of(body)
        [ Tables.framed(File.basename(reference.locator_key.to_s), CSV.parse(body, col_sep: separator).first(Tables::ROWS + 1)) ].compact
      rescue CSV::MalformedCSVError
        []
      end

      def shape_of(body)
        case File.extname(reference.locator_key.to_s).downcase
        when ".json"
          parsed = JSON.parse(body)
          { "format" => "json", "keys" => Array(parsed.is_a?(Hash) ? parsed.keys : nil).first(50) }
        when ".csv", ".tsv"
          rows = CSV.parse(body, col_sep: File.extname(reference.locator_key).casecmp(".tsv").zero? ? "\t" : ",")
          { "format" => "csv", "columns" => rows.first || [], "rows" => [ rows.length - 1, 0 ].max }
        else
          { "format" => "unknown" }
        end
      rescue JSON::ParserError, CSV::MalformedCSVError => e
        { "format" => "invalid", "error" => e.message.truncate(200) }
      end
  end
end
