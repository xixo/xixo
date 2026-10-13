ENV["RAILS_ENV"] = "test"
ENV["XIXO_TENANT"] = "xixo"
%w[MASKS_ISSUER_TEMPLATE XIXO_TENANTS XIXO_PUBLIC_ORIGIN].each { |name| ENV.delete(name) }

require_relative "../../config/environment"

primary, masks = %w[primary masks].map { |name| ActiveRecord::Base.configurations.configs_for(env_name: "test", name: name) }
ActiveRecord::Tasks::DatabaseTasks.create(masks)
ActiveRecord::Tasks::DatabaseTasks.purge(masks)
ActiveRecord::Base.establish_connection(masks)
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.connection_pool.migration_context.migrate
ActiveRecord::Base.establish_connection(primary)

require "rails/test_help"
require_relative "../support/offline"
require_relative "../support/fake_search_engine"

SearchIndex.define_singleton_method(:client) { @client ||= FakeSearchEngine.new }


Tenant.declare!
Masks::Server::Tenant.declare!

class EmbeddedTest < ActionDispatch::IntegrationTest
  ORIGIN = "https://xixo.test".freeze
  ISSUER = "#{ORIGIN}/id".freeze
  PASSWORD = "a-long-enough-password".freeze

  setup do
    https!
    host! "xixo.test"
    Masks::Client.registry.clear!
  end

  teardown do
    Tenant.clear!
    Masks::Server::Tenant.clear!
  end

  def tenant
    Tenant.find_by!(subdomain: "xixo")
  end

  def masks_tenant
    Masks::Server::Tenant.find_by!(subdomain: "xixo")
  end

  def json
    JSON.parse(response.body)
  end

  def query(location)
    Rack::Utils.parse_query(URI.parse(location).query)
  end

  def path_of(location)
    uri = URI.parse(location)

    [ uri.path, uri.query ].compact.join("?")
  end

  def hidden_value(name, body = response.body)
    body[/name="#{name}"[^>]*value="([^"]*)"/, 1]
  end

  def set_up_owner!
    post "/id/login", params: { event: "signup", token: masks_tenant.setup_token!, nickname: "owner",
                                email: "owner@example.invalid", password: PASSWORD,
                                password_confirmation: PASSWORD }, as: :json

    secret = json.dig("enrolment", "otp", "secret").to_s.delete(" ")

    post "/id/login", params: { event: "enrol:otp", code: ROTP::TOTP.new(secret).now }, as: :json
    post "/id/login", params: { event: "enrol:done", kept: "1" }, as: :json
    post "/id/login", params: { event: "setup-configure", called: "xixo" }, as: :json

    json
  end
end
