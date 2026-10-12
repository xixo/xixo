class Resource
  class Machine
    class Reading
      TAKEN = 16

      def initialize(machine, exchange, size:, request: nil, parent: nil)
        @machine = machine
        @exchange = exchange
        @size = size
        @request = request
        @parent = parent
        @next = 0
        @written = 0
        @moved_at = Time.current
      end

      def file
        raise Resource::Failed, "#{@machine.key}: xixo link said nothing of the size it sent" unless @size.is_a?(Integer) && @size >= 0

        held = Tempfile.new("xixo-link", binmode: true)

        LinkExchange.apart do
          until done?
            taken = take(held)
            next if taken.positive?

            stalled! if Time.current - @moved_at > READ_STALLS_AFTER
            @machine.waiting
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
          @exchange ||= LinkExchange.uncached do
            LinkExchange.find_by(resource_id: @machine.id, request: @request, parent_id: @parent.id)
          end
        end

        def take(held)
          return 0 if exchange.nil?

          chunks = LinkChunk.uncached do
            LinkChunk.where(link_exchange_id: exchange.id, seq: @next...(@next + TAKEN)).order(:seq).to_a
          end
          contiguous = chunks.each_with_index.take_while { |chunk, index| chunk.seq == @next + index }.map(&:first)
          return 0 if contiguous.empty?

          contiguous.each { |chunk| held.write(chunk.bytes) }
          @written += contiguous.sum { |chunk| chunk.bytes.bytesize }
          @next += contiguous.size
          @moved_at = Time.current
          LinkChunk.where(id: contiguous.map(&:id)).delete_all
          raise Resource::Failed, "#{@machine.key}: xixo link sent more than it said it would" if @written > @size

          contiguous.size
        end

        def done?
          return @written == @size if exchange.nil?

          held = LinkExchange.uncached { LinkExchange.find(exchange.id) }
          raise Refusal, "#{@machine.key}: xixo link said #{held.error}" if held.refused?

          @written == @size
        end

        def stalled!
          exchange&.refuse!("stalled")

          raise Resource::Failed, "#{@machine.key}: xixo link stopped sending for #{READ_STALLS_AFTER.inspect}"
        end
    end
  end
end
