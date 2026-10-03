Rails.application.config.to_prepare do
  Masks::Rails.configure do |config|
    config.name = Rails.application.class.module_parent_name
    config.issuer = ->(request) { Tenant.issuer_url(request) }
    config.resource = ->(request) { Tenant.resource_url(request) }
    config.redirect_uri = ->(request) { Tenant.redirect_url(request) }
    config.credentials = ->(request) { Tenant.resolve(request.host)&.masks_credentials }
    config.store = ->(request, registration) { Tenant.resolve!(request.host).connect!(registration) }
    config.forget = ->(request) { Tenant.resolve!(request.host).disconnect! }
    config.resource_scopes = Grant::OFFERED
    config.namespace = Grant::NAMESPACE
    config.scope = Masks::Client::Session::DEFAULT_SCOPE + [ "offline_access" ] + Grant::SIGN_IN
    config.after_sign_in = "/"
    config.after_sign_out = "/"
    config.delegates = true
    config.delegation_redirect_uri = ->(request) { "#{Tenant.origin(request)}#{Delegations::CALLBACK_PATH}" }
  end
end
