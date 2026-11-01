class LinkCliController < ActionController::API
  PENDING = %w[authorization_pending slow_down].freeze

  rate_limit to: 30, within: 1.minute, by: -> { request.remote_ip },
             with: -> { refused("slow_down", "too many tries from this address. Wait a minute", :too_many_requests) }

  before_action :no_store

  def device
    unless Current.tenant.grants_devices!
      return refused("unauthorized_client", "masks does not let this xixo sign people in from the command line. " \
                                            "A manager of masks adds the device grant to its client", :service_unavailable)
    end

    device = session.device_authorization(scope: Grant::SCOPES, resource: Tenant.resource_url(request))

    render json: {
      device_code: device.device_code, user_code: device.user_code, verification_uri: device.verification_uri,
      verification_uri_complete: device.verification_uri_complete, expires_in: device.expires_in, interval: device.interval
    }
  rescue Masks::Client::Refused => e
    refused(e.code, e.message, :bad_request)
  rescue Tenant::Unconfigured, Masks::Client::Error => e
    refused("server_error", e.message, :service_unavailable)
  end

  def token
    tokens = if params[:refresh_token].present?
      session.refresh(params[:refresh_token].to_s, resource: Tenant.resource_url(request))
    else
      session.send(:token, [ [ "grant_type", Masks::Client::Device::GRANT_TYPE ],
                             [ "device_code", params[:device_code].to_s ], [ "client_id", credentials[:client_id] ] ])
    end

    render json: { access_token: tokens.access_token, refresh_token: tokens.refresh_token, expires_in: tokens.expires_in,
                   scope: tokens.scope, token_type: "Bearer" }.compact
  rescue Masks::Client::Refused => e
    refused(e.code, e.message, PENDING.include?(e.code) ? :bad_request : :unauthorized)
  rescue Tenant::Unconfigured, Masks::Client::Error => e
    refused("server_error", e.message, :service_unavailable)
  end

  private

    def credentials
      Current.tenant.masks_credentials || raise(Tenant::Unconfigured, "this xixo is not connected to masks yet")
    end

    def session
      @session ||= Masks::Client::Session.new(issuer: Current.tenant.issuer, client_id: credentials[:client_id],
                                              client_secret: credentials[:client_secret])
    end

    def refused(error, description, status)
      render status: status, json: { error: error, error_description: description }
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end
end
