class Resource
  class Machine
    class Answer
      attr_reader :exchange, :result

      def initialize(machine, exchange, result)
        @machine = machine
        @exchange = exchange
        @result = result
      end

      def files
        Array(result.to_h["files"]).select { |file| file.is_a?(Hash) }
      end

      def file(entry)
        id = entry.to_h["request_file"]
        size = entry.to_h["size"]
        raise Resource::Failed, "#{@machine.key}: xixo link named a file without an id" unless LinkExchange.uuid?(id)
        raise Resource::Failed, "#{@machine.key}: xixo link named a file without a size" unless size.is_a?(Integer) && size >= 0

        Reading.new(@machine, nil, size: size, request: id, parent: exchange).file
      end
    end
  end
end
