module EmbeddedIssuer
  PATH = "/id".freeze
  INSERTED = %w[/.well-known/oauth-authorization-server /.well-known/openid-configuration].freeze

  module_function

  def chosen?
    return @chosen if defined?(@chosen)

    @chosen = ENV["MASKS_ISSUER_TEMPLATE"].blank?
  end

  def on?
    Rails.configuration.xixo.embedded
  end

  def migrations
    File.join(Gem.loaded_specs.fetch("masks-server").full_gem_path, "db/migrate")
  end

  def url(origin)
    "#{origin.chomp('/')}#{PATH}"
  end

  def template(origin)
    origin.presence && url(origin)
  end

  def serves?(uri)
    return false unless uri.path == PATH || uri.path.start_with?("#{PATH}/")
    return Rails.env.local? if ENV["XIXO_PUBLIC_ORIGIN"].blank?

    Masks::Client::Nonces.origin(Tenant.origin_for(Tenant.subdomain_for(uri.host)).chomp("/")) == Masks::Client::Nonces.origin(uri)
  end

  def call(env)
    Rails.application.executor.wrap do
      status, headers, body = engine(env.merge("SCRIPT_NAME" => PATH, "PATH_INFO" => env["PATH_INFO"].delete_prefix(PATH)))

      [ status, headers, body.to_enum(:each).to_a ]
    ensure
      body.close if body.respond_to?(:close)
    end
  end

  def inserted
    ->(env) { engine(env.merge("SCRIPT_NAME" => "#{env['SCRIPT_NAME']}#{PATH}", "PATH_INFO" => env["PATH_INFO"].delete_suffix(PATH))) }
  end

  def engine(env)
    Masks::Server::Engine.call(Rails.application.env_config.merge(env))
  end
end
