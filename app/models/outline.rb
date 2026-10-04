module Outline
  HEADING = /^[ \t]{0,3}\#{1,6}[ \t]+(.+?)[ \t#]*$/
  PAGE = "\f".freeze
  STAMP = /^\[(\d{2}):(\d{2}):\d{2}\]/
  MOST = 200

  class << self
    def of(text, stored: nil)
      return Array(stored).first(MOST) if stored.present?

      body = text.to_s
      headings(body).presence || pages(body).presence || minutes(body)
    end

    def at(outline, offset)
      outline.select { |part| part["from"].to_i <= offset }.max_by { |part| part["from"].to_i }&.dig("name")
    end

    def starts(outline)
      outline.map { |part| part["from"].to_i }.select(&:positive?).uniq.sort
    end

    def span(outline, from, length)
      [ from, starts(outline).find { |at| at > from } || length ]
    end

    private

      def headings(body)
        body.to_enum(:scan, HEADING).map do
          { "name" => Regexp.last_match(1).strip, "from" => Regexp.last_match.begin(0) }
        end.first(MOST)
      end

      def minutes(body)
        seen = nil

        body.to_enum(:scan, STAMP).filter_map do
          minute = Regexp.last_match(1).to_i * 60 + Regexp.last_match(2).to_i
          next if minute == seen

          seen = minute
          { "name" => Regexp.last_match(0).delete("[]"), "from" => Regexp.last_match.begin(0) }
        end.first(MOST)
      end

      def pages(body)
        breaks = body.to_enum(:scan, PAGE).map { Regexp.last_match.end(0) }
        return [] if breaks.empty?

        [ 0, *breaks ].reject { |from| from >= body.length }.first(MOST).each_with_index.map do |from, index|
          { "name" => "Page #{index + 1}", "from" => from }
        end
      end
  end
end
