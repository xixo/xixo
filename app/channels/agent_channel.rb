class AgentChannel < ApplicationCable::Channel
  periodically :expire, every: 15.seconds

  def subscribed
    return reject if machine.nil? || !current?

    @session = SecureRandom.uuid
    stream_for machine
  end

  def hello(data)
    within { |agent| agent.greeted!(data, session: @session) }
  end

  def health(data)
    within { |agent| agent.heard!(data) }
  end

  def reply(data)
    within do |agent|
      exchange = AgentExchange.for(agent, data["request"])
      next if exchange.nil?

      if data["ok"] == true
        result = data["result"]
        next exchange.refuse!("the answer was larger than #{Resource::XixoAgent::MOST_RESULT} bytes") if result.to_json.bytesize > Resource::XixoAgent::MOST_RESULT

        exchange.answer!(result)
      else
        exchange.refuse!(Resource::XixoAgent::Hello.text(data["error"]) || "the agent refused")
      end
    end
  end

  def chunk(data)
    within do |agent|
      exchange = AgentExchange.receiving(agent, data["request"], of: data["of"])
      seq = data["seq"]
      next if exchange.nil?
      next exchange.refuse!("a chunk's place was not a number it could keep") unless seq.is_a?(Integer) && seq.between?(0, AgentExchange::MOST_SEQ)

      bytes = Base64.strict_decode64(data["data"].to_s)
      exchange.refuse!("a chunk could not be kept") unless exchange.receive!(seq, bytes)
    rescue ArgumentError
      exchange&.refuse!("a chunk was not base64")
    end
  end

  def unsubscribed
    return unless machine && @session

    Tenant.switch(tenant) { Resource::XixoAgent.find_by(id: machine.id)&.parted!(session: @session) }
  end

  private

    def within
      Tenant.switch(tenant) do
        agent = Resource::XixoAgent.enrolled(client_id)
        next yield agent if agent&.id == machine.id

        connection.close(reason: "unauthorized", reconnect: false)
      end
    end

    def current?
      Tenant.switch(tenant) { Resource::XixoAgent.enrolled(client_id)&.id == machine.id }
    end

    def expire
      held = current?
      return unless connection.expired? || !held

      connection.close(reason: "unauthorized", reconnect: held)
    end
end
