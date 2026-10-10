require "zip"

module Analyzer
  class Pkpass < Base
    FIELD_GROUPS = %w[headerFields primaryFields secondaryFields auxiliaryFields backFields].freeze
    STYLES = %w[boardingPass coupon eventTicket generic storeCard].freeze

    def self.handles?(feed)
      feed.mime == "application/vnd.apple.pkpass"
    end

    def analyze
      pass = step(:pass) { parse(read_pass_json) }

      step(:text) { capped(flatten(pass)) }
    end

    private

      def read_pass_json
        with_tempfile do |path|
          Zip::File.open(path) do |zip|
            entry = zip.find_entry("pass.json")
            raise Analyzer::Failed, "no pass.json in the bundle" if entry.nil?

            entry.get_input_stream.read
          end
        end
      rescue Zip::Error => e
        raise Analyzer::Failed, "unreadable pkpass: #{e.message.truncate(200)}"
      end

      def parse(body)
        pass = JSON.parse(body)
        style = STYLES.find { |candidate| pass.key?(candidate) }

        {
          "style" => style,
          "organization" => pass["organizationName"],
          "description" => pass["description"],
          "logo_text" => pass["logoText"],
          "serial_number" => pass["serialNumber"],
          "relevant_date" => pass["relevantDate"],
          "expiration_date" => pass["expirationDate"],
          "fields" => fields_of(pass[style])
        }
      rescue JSON::ParserError => e
        raise Analyzer::Failed, "pass.json is not json: #{e.message.truncate(200)}"
      end

      def fields_of(body)
        return [] unless body.is_a?(Hash)

        FIELD_GROUPS.flat_map { |group| Array(body[group]) }.filter_map do |field|
          next unless field.is_a?(Hash)

          { "label" => field["label"], "value" => field["value"].to_s }
        end
      end

      def flatten(pass)
        described = pass.except("fields").values.compact
        labelled = pass["fields"].map { |field| [ field["label"], field["value"] ].compact.join(": ") }

        (described + labelled).join("\n")
      end
  end
end
