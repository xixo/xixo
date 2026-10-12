class LinkChannel < ApplicationCable::Channel
  periodically :expire, every: 15.seconds

  def subscribed
    return reject if machine.nil? || !current?

    @session = SecureRandom.uuid
    stream_for machine
  end

  def hello(data)
    within { |linked| linked.greeted!(data, session: @session) }
  end

  def health(data)
    within { |linked| linked.heard!(data) }
  end

  def changed(data)
    within { |linked| linked.changed!(data) }
  end

  def reply(data)
    within do |linked|
      exchange = LinkExchange.for(linked, data["request"])
      next if exchange.nil?

      if data["ok"] == true
        result = data["result"]
        next exchange.refuse!("the answer was larger than #{Resource::Machine::MOST_RESULT} bytes") if result.to_json.bytesize > Resource::Machine::MOST_RESULT

        exchange.answer!(result)
      else
        exchange.refuse!(Resource::Machine::Hello.text(data["error"]) || "xixo link refused")
      end
    end
  end

  def chunk(data)
    within do |linked|
      exchange = LinkExchange.receiving(linked, data["request"], of: data["of"])
      seq = data["seq"]
      next if exchange.nil?
      next exchange.refuse!("a chunk's place was not a number it could keep") unless seq.is_a?(Integer) && seq.between?(0, LinkExchange::MOST_SEQ)

      bytes = Base64.strict_decode64(data["data"].to_s)
      exchange.refuse!("a chunk could not be kept") unless exchange.receive!(seq, bytes)
    rescue ArgumentError
      exchange&.refuse!("a chunk was not base64")
    end
  end

  def unsubscribed
    return unless machine && @session

    Tenant.switch(tenant) { Resource::Machine.find_by(id: machine.id)&.parted!(session: @session) }
  end

  private

    def within
      Tenant.switch(tenant) do
        linked = Resource::Machine.enrolled(client_id)
        next yield linked if linked&.id == machine.id

        connection.close(reason: ApplicationCable::Connection::UNKNOWN_MACHINE, reconnect: false)
      end
    end

    def current?
      Tenant.switch(tenant) { Resource::Machine.enrolled(client_id)&.id == machine.id }
    end

    def expire
      return connection.close(reason: ApplicationCable::Connection::UNKNOWN_MACHINE, reconnect: false) unless current?

      connection.close(reason: "unauthorized", reconnect: true) if connection.expired?
    end
end
