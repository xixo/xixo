module ResourceServer
  module_function

  def for(request)
    config = Masks::Rails.config
    url = Array(config.resource_for(request)).first || raise(Masks::Rails::Configuration::Unconfigured, "Masks::Rails.config.resource is not set")

    Masks::Client::Resource.new(issuer: config.issuer_for(request), url: url, scopes: config.resource_scopes, replay: ProofMark)
  end
end
