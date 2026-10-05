module Analyzer
  class Calendar < Base
    MAX_EVENTS = 200
    WRITTEN_AS = "dates as they are read".freeze
    STAMP = /\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})\d{2}(Z)?)?\z/

    def self.handles?(feed)
      feed.mime == "text/calendar"
    end

    def analyze
      body = readable(reference.download.read)

      events = step(:events) { parse(body) }

      step(:text, digest: WRITTEN_AS) { flatten(events).truncate(MAX_TEXT) }
    end

    SUMMARY_EVENTS = 20

    def summary_prompt
      events = step_result(:events) || []
      return super if events.empty?

      lines = events.first(SUMMARY_EVENTS).map do |event|
        "- #{[ self.class.read_as(event['dtstart']), event['summary'], event['location'] ].compact_blank.join(' — ')}"
      end

      <<~PROMPT
        Summarize the calendar below.

        Filename: #{reference.filename}
        Events: #{events.size}

        #{fenced("First #{lines.size} of #{events.size} events:\n#{lines.join("\n")}")}
        #{summary_shape(SAYS)}
      PROMPT
    end

    def self.read_as(stamp)
      parts = stamp.to_s.match(STAMP)
      return stamp if parts.nil?

      day = Date.new(parts[1].to_i, parts[2].to_i, parts[3].to_i).strftime("%A, %B %-d, %Y")
      parts[4] ? "#{day}, #{parts[4]}:#{parts[5]}#{' UTC' if parts[6]}" : day
    rescue Date::Error
      stamp
    end

    SAYS = "one or two sentences on what is on this calendar and over what period. " \
           "Name the events, the people and the places rather than counting them."

    private

      def unfold(body)
        body.gsub(/\r?\n[ \t]/, "")
      end

      def unescape(value)
        value.gsub(/\\([nN,;\\])/) do
          escaped = Regexp.last_match(1)
          escaped.casecmp?("n") ? "\n" : escaped
        end
      end

      def parse(body)
        events = []
        current = nil

        unfold(body).each_line do |line|
          line = line.strip
          next if line.empty?

          case line
          when "BEGIN:VEVENT" then current = {}
          when "END:VEVENT"
            events << current if current
            current = nil
            break if events.size >= MAX_EVENTS
          else
            assign(current, line) if current
          end
        end

        events
      end

      def assign(event, line)
        name, value = line.split(":", 2)
        return if value.nil?

        key = name.split(";").first.to_s.downcase
        return unless %w[summary description location dtstart dtend organizer status uid].include?(key)

        event[key] = unescape(value).truncate(CELL_LIMIT)
      end

      CELL_LIMIT = 1000

      def flatten(events)
        events.map do |event|
          [ event["summary"], self.class.read_as(event["dtstart"]), event["location"], event["description"] ]
            .compact.join(" · ")
        end.join("\n")
      end
  end
end
