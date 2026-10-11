module Granted
  extend ActiveSupport::Concern
  include Masks::Rails::Authentication
  include Masks::Rails::ProtectedResource

  included do
    before_action :authorize
  end

  private

    def verified_request?
      request.authorization.present? || super
    end

    def grant
      @grant ||= Grant.new(tenant: current_tenant, claims: masks_claims_from(credentials)).tap do |held|
        Current.grant = held
        Current.audit = audit_context
        Current.origin = Tenant.origin(request)
      end
    end

    def authorize
      grant
    rescue Grant::Denied => e
      denied(e)
      refuse(Masks::Client::Unauthorized.new(e.message))
    rescue Masks::Client::Challenge => e
      denied(e)
      refuse(e)
    rescue Tenant::Unconfigured, Masks::Client::Unreachable => e
      unavailable(e)
    end

    def audit_channel
      controller_name
    end

    def caller_key
      presented = request.authorization.to_s[/\ABearer (\S+)\z/, 1]
      held = presented ? "token:#{Digest::SHA256.hexdigest(presented)}" : "ip:#{request.remote_ip}"

      [ current_tenant.id, held ].join(":")
    end

    def too_many
      AuditEvent.record(
        channel: audit_channel, action: "authorize", status: "denied",
        context: audit_context, detail: "too many requests", told: "asked too often and was turned away"
      )

      render json: {
        jsonrpc: "2.0", id: nil,
        error: { code: -32_000, message: "too many requests" }
      }, status: :too_many_requests
    end

    def audit_context
      { remote_ip: request.remote_ip, request_id: request.request_id }
    end

    def denied(error)
      AuditEvent.record(
        channel: audit_channel, action: "authorize", status: "denied",
        context: audit_context, detail: error.message, told: "was not let in"
      )
    end

    def masks_claims_from(authorization)
      masks_resource.authenticate(authorization)
    end

    def credentials
      request.authorization.presence || session_authorization
    end

    def session_authorization
      return nil unless masks_signed_in? || (masks_tokens && masks_refresh!)

      "Bearer #{masked.access_token}"
    end

    def presented?
      request.authorization.present?
    end

    def refuse(error)
      presented? ? masks_challenge(error) : masks_refuse_json

      false
    end

    def unavailable(error)
      render json: {
        error: "server_error",
        error_description: error.message
      }, status: :service_unavailable

      false
    end
end
