class Resource
  class XixoAgent
    class Reading
      TAKEN = 16

      def initialize(agent, exchange, size:, request: nil, parent: nil)
        @agent = agent
        @exchange = exchange
        @size = size
        @request = request
        @parent = parent
        @next = 0
        @written = 0
        @moved_at = Time.current
      end

      def file
        raise Resource::Failed, "#{@agent.key}: the agent said nothing of the size it sent" unless @size.is_a?(Integer) && @size >= 0

        held = Tempfile.new("xixo-agent", binmode: true)

        AgentExchange.apart do
          until done?
            taken = take(held)
            next if taken.positive?

            stalled! if Time.current - @moved_at > READ_STALLS_AFTER
            @agent.waiting
          end
        end

        held.flush
        held.rewind
        held
      rescue StandardError
        held&.close!
        raise
      end

      private

        def exchange
          @exchange ||= AgentExchange.uncached do
            AgentExchange.find_by(resource_id: @agent.id, request: @request, parent_id: @parent.id)
          end
        end

        def take(held)
          return 0 if exchange.nil?

          chunks = AgentChunk.uncached do
            AgentChunk.where(agent_exchange_id: exchange.id, seq: @next...(@next + TAKEN)).order(:seq).to_a
          end
          contiguous = chunks.each_with_index.take_while { |chunk, index| chunk.seq == @next + index }.map(&:first)
          return 0 if contiguous.empty?

          contiguous.each { |chunk| held.write(chunk.bytes) }
          @written += contiguous.sum { |chunk| chunk.bytes.bytesize }
          @next += contiguous.size
          @moved_at = Time.current
          AgentChunk.where(id: contiguous.map(&:id)).delete_all
          raise Resource::Failed, "#{@agent.key}: the agent sent more than it said it would" if @written > @size

          contiguous.size
        end

        def done?
          return @written == @size if exchange.nil?

          held = AgentExchange.uncached { AgentExchange.find(exchange.id) }
          raise Refusal, "#{@agent.key}: the agent said #{held.error}" if held.refused?

          @written == @size
        end

        def stalled!
          exchange&.refuse!("stalled")

          raise Resource::Failed, "#{@agent.key}: the agent stopped sending for #{READ_STALLS_AFTER.inspect}"
        end
    end
  end
end
