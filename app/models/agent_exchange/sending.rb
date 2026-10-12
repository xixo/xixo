class AgentExchange
  class Sending
    TAKEN = 16

    def initialize(exchange)
      @exchange = exchange
      @tenant = Current.tenant
    end

    def each
      from = 0

      loop do
        chunks = Tenant.switch(@tenant) do
          AgentChunk.where(agent_exchange_id: @exchange.id, seq: from...(from + TAKEN)).order(:seq).to_a
        end
        break if chunks.empty?

        chunks.each { |chunk| yield chunk.bytes }
        Tenant.switch(@tenant) { AgentChunk.where(id: chunks.map(&:id)).delete_all }
        from += chunks.size
      end
    end
  end
end
