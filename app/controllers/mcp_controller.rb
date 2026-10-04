class McpController < ApplicationController
  include ActionController::Live

  around_action :within_tenant

  rate_limit to: Rails.configuration.xixo.mcp_limit, within: 1.minute,
             by: -> { caller_key }, with: -> { too_many }

  include Granted

  skip_forgery_protection

  def handle
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

    def deliver(body)
      if body.respond_to?(:call)
        body.call(response.stream)
      else
        body.each { |chunk| response.stream.write(chunk) }
      end
    ensure
      response.stream.close
    end
end
