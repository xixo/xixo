module Analyzer
  class Calendar < Base
    STAMP = /\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})\d{2}(Z)?)?\z/
    SUMMARY_EVENTS = 20

    def self.handles?(feed)
      feed.mime == "text/calendar"
    end

    def summary_prompt
      events = step_list(:events).select { |event| event.is_a?(Hash) }
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
  end
end
