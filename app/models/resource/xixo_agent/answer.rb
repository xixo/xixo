class Resource
  class XixoAgent
    class Answer
      attr_reader :exchange, :result

      def initialize(agent, exchange, result)
        @agent = agent
        @exchange = exchange
        @result = result
      end

      def files
        Array(result.to_h["files"]).select { |file| file.is_a?(Hash) }
      end

      def file(entry)
        id = entry.to_h["request_file"]
        size = entry.to_h["size"]
        raise Resource::Failed, "#{@agent.key}: the agent named a file without an id" unless AgentExchange.uuid?(id)
        raise Resource::Failed, "#{@agent.key}: the agent named a file without a size" unless size.is_a?(Integer) && size >= 0

        Reading.new(@agent, nil, size: size, request: id, parent: exchange).file
      end
    end
  end
end
