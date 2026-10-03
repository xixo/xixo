class Agent
  class Clock
    NAME = "more_time".freeze
    CLOSING = 1.minute

    DECLARED = {
      type: "function",
      function: {
        name: NAME,
        description: "Ask for more time when the work needs longer than you have left. Say how many " \
                     "more minutes and why. A run never lasts more than a day.",
        parameters: {
          type: "object",
          properties: {
            minutes: { type: "integer", description: "How many more minutes the work needs." },
            reason: { type: "string", description: "Why, in one sentence." }
          },
          required: %w[minutes reason]
        }
      }
    }.freeze

    def initialize(analysis, reserve: 0)
      @analysis = analysis
      @reserve = reserve
    end

    def running?
      @analysis&.deadline.present?
    end

    def told
      return nil unless running?

      "You have about #{minutes_left} minutes for this. If the work needs longer, call #{NAME} with " \
        "how many more minutes and why; a run never lasts more than a day."
    end

    def closing?
      running? && @analysis.time_left < CLOSING + @reserve
    end

    def declared
      running? ? [ DECLARED ] : []
    end

    def handles?(raw)
      running? && raw.to_h.dig("function", "name") == NAME
    end

    def spent?
      running? && @reserve.positive? && @analysis.time_left < @reserve
    end

    def call_all(raws)
      raws.map { |raw| call(raw) }
    end

    def call(raw)
      arguments = parsed(raw)
      wanted = arguments["minutes"].to_i
      reason = arguments["reason"].to_s.squish

      return refused(arguments, "#{NAME} needs minutes above zero and a reason") if wanted <= 0 || reason.empty?

      before = @analysis.deadline
      granted = @analysis.more_time!(wanted.clamp(1, Feed::MAX_TIMEOUT.in_minutes.to_i).minutes)
      capped = before && granted < before + wanted.minutes

      @analysis.log_info("agent", NAME, "#{wanted} minutes", reason.truncate(200))

      Dispatch::Result.new(
        name: NAME, arguments: arguments, ok: true, error: nil,
        content: { minutes_left: minutes_left, deadline: granted.iso8601,
                   capped: capped ? "a run never lasts more than a day, so this is all the time there is" : nil }.compact.to_json
      )
    end

    private

      def minutes_left
        ([ @analysis.time_left - @reserve, 0 ].max / 60.0).floor
      end

      def parsed(raw)
        held = JSON.parse(raw.to_h.dig("function", "arguments").to_s)
        held.is_a?(Hash) ? held : {}
      rescue JSON::ParserError
        {}
      end

      def refused(arguments, complaint)
        Dispatch::Result.new(name: NAME, arguments: arguments, ok: false, error: complaint,
                             content: { error: complaint }.to_json)
      end
  end
end
