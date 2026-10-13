class McpController < ApplicationController
  include ActionController::Live

  class Stream
    def initialize(stream)
      @stream = stream
    end

    def write(chunk)
      @stream.write(chunk)
    rescue ActionController::Live::ClientDisconnected => e
      raise IOError, e.message
    end

    def flush
      raise IOError, "closed stream" if closed?
    end

    def closed?
      @stream.closed?
    end

    def close
      @stream.close
    end
  end

  around_action :within_tenant

  rate_limit to: Rails.configuration.xixo.mcp_limit, within: 1.minute,
             by: -> { caller_key }, with: -> { too_many }

  include Granted

  skip_forgery_protection

  def handle
    return refuse_stream if request.get?

    status, headers, body = transport.call(request.env)

    headers.each { |name, value| response.headers[name] = value }
    self.status = status

    remember_session(headers)
    deliver(body)
  end

  private

    def within_tenant(&)
      Tenant.switch(current_tenant, &)
    end

    def presented?
      true
    end

    def transport
      McpTransports.for(tenant: current_tenant, grant: grant)
    end

    def remember_session(headers)
      issued = headers[McpTransports::SESSION_HEADER] || headers[McpTransports::SESSION_HEADER.downcase]

      McpTransports.claim(issued, grant.subject)
      McpTransports.forget(issued) if request.delete? && issued.present?
    end

    def refuse_stream
      response.headers["Allow"] = "POST, DELETE"
      head :method_not_allowed
    end

    def deliver(body)
      if body.respond_to?(:call)
        body.call(Stream.new(response.stream))
      else
        body.each { |chunk| response.stream.write(chunk) }
      end
    ensure
      response.stream.close
    end
end
