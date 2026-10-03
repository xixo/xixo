require "json"

class Resource
  class OpenaiCompatible
    class Gathering
      def initialize(streamed:)
        @streamed = streamed
        @raw = +""
        @pending = +""
        @content = +""
        @reasoning = +""
        @calls = {}
      end

      def <<(chunk)
        @streamed ? take(chunk) : @raw << chunk
        self
      end

      def message
        return JSON.parse(@raw).dig("choices", 0, "message") || {} unless @streamed

        take("\n")

        {
          "role" => "assistant",
          "content" => @content,
          "reasoning" => @reasoning.presence,
          "tool_calls" => (@calls.sort.map(&:last) if @calls.any?)
        }.compact
      end

      private

        def take(chunk)
          @pending << chunk

          while (ended = @pending.index("\n"))
            line = @pending.slice!(0..ended).strip
            next unless line.start_with?("data:")

            data = line.delete_prefix("data:").strip
            next if data.empty? || data == "[DONE]"

            heard(JSON.parse(data))
          end
        end

        def heard(event)
          raise Resource::Failed, event.dig("error", "message").presence || event["error"].to_s if event["error"]

          delta = event.dig("choices", 0, "delta") || {}
          @content << delta["content"].to_s
          @reasoning << (delta["reasoning"] || delta["reasoning_content"]).to_s

          Array(delta["tool_calls"]).each_with_index { |call, at| called(call, at) }
        end

        def called(call, at)
          held = @calls[call["index"] || at] ||= { "id" => nil, "type" => "function", "function" => { "name" => +"", "arguments" => +"" } }
          held["id"] ||= call["id"]
          held["function"]["name"] << call.dig("function", "name").to_s
          held["function"]["arguments"] << call.dig("function", "arguments").to_s
        end
    end
  end
end
