module Analyzer
  class Fallback < Base
    SHOWN = 50

    def self.handles?(_feed)
      true
    end

    def self.summary_role
      :fast
    end

    def summary_body
      text = step_result(:text).to_s.strip
      return fenced(text) if text.present?

      names = step_list(:listing).map(&:to_s)
      return fenced("Archive entries:\n#{names.first(SHOWN).join("\n")}") if names.any?

      UNREAD
    end

    def file_facts
      [ super, format_facts ].compact_blank.join("\n")
    end

    private

      def format_facts
        found = step_hash(:format)
        return nil if found.blank?

        declared = found["declared"].to_s
        seen = found["observed"]
        return "Format: #{seen}" if declared.blank? || declared == "application/octet-stream"

        "Format: #{seen}, declared as #{declared}"
      end
  end
end
