module EmbeddedIssuer
  PATH = "/id".freeze
  INSERTED = %w[/.well-known/oauth-authorization-server /.well-known/openid-configuration].freeze

  module_function

  def on?
    Rails.configuration.xixo.embedded == true
  end

  def migrations
    on? ? Masks::Server::Engine.root.join("db/migrate").to_s : "db/masks_migrate"
  end

  def url(origin)
    "#{origin.chomp('/')}#{PATH}"
  end

  def template(origin)
    origin.presence && url(origin)
  end

  def serves?(uri)
    return false unless uri.path == PATH || uri.path.start_with?("#{PATH}/")

    public_origin = ENV["XIXO_PUBLIC_ORIGIN"].presence
    return Rails.env.local? if public_origin.nil?

    port = ":#{uri.port}" unless uri.port == uri.default_port
    format(public_origin, subdomain: Tenant.subdomain_for(uri.host)).chomp("/") == "#{uri.scheme}://#{uri.host}#{port}"
  end

  def call(env)
    Rails.application.executor.wrap do
      inside(env.merge("SCRIPT_NAME" => PATH, "PATH_INFO" => env["PATH_INFO"].delete_prefix(PATH)))
    end
  end

  def inserted
    lambda do |env|
      inside(env.merge("SCRIPT_NAME" => "#{env['SCRIPT_NAME']}#{PATH}", "PATH_INFO" => env["PATH_INFO"].delete_suffix(PATH)))
    end
  end

  def inside(env)
    status, headers, body = Masks::Server::Engine.call(Rails.application.env_config.merge(env))
    held = []

    body.each { |chunk| held << chunk }

    [ status, headers, held ]
  ensure
    body.close if body.respond_to?(:close)
  end
end
