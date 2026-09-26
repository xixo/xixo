class Tenant < ApplicationRecord
  class Unconfigured < Masks::Client::Error; end

  class Exposed < StandardError
    def initialize(role)
      super(
        "this server connects to Postgres as #{role || 'a role it cannot read back'}, which sees " \
        "through row-level security. Every tenant_isolation policy on the database is decorative " \
        "while it does, and the only thing left between one tenant and another's items, resources " \
        "and grants is a default scope in Ruby. Connect as a role holding neither SUPERUSER nor " \
        "BYPASSRLS."
      )
    end
  end

  encrypts :client_secret
  encrypts :registration_access_token

  has_many :feeds, dependent: :destroy
  has_many :resources, dependent: :destroy

  validates :subdomain, presence: true, uniqueness: true,
                        format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
  validates :name, presence: true

  after_create_commit { SearchIndex.create_alias!(self) }

  def connected?
    client_id.present? && client_secret.present?
  end

  def masks_credentials
    return nil unless connected?

    {
      client_id: client_id,
      client_secret: client_secret,
      registration_access_token: registration_access_token,
      registration_client_uri: registration_client_uri
    }
  end

  def issuer
    self.class.issuer_for(subdomain)
  end

  def origin
    override = ENV["URIS_PUBLIC_ORIGIN"].presence
    raise Unconfigured, "URIS_PUBLIC_ORIGIN is not set, so #{subdomain} has no address outside a request" if override.nil?

    format(override, subdomain: subdomain)
  end

  def disconnect!
    update!(
      client_id: nil, client_secret: nil,
      registration_access_token: nil, registration_client_uri: nil,
      connected_at: nil
    )
  end

  def connect!(registration)
    update!(
      client_id: registration.client_id,
      client_secret: registration.client_secret,
      registration_access_token: registration.access_token,
      registration_client_uri: registration.uri,
      connected_at: Time.current
    )
  end

  class TenancyConflict < StandardError
    def initialize(message = "URIS_TENANT and URIS_TENANTS are both set; declare one or the other")
      super
    end
  end

  class << self
    def pinned
      Rails.configuration.uris.tenant
    end

    def declared
      return Rails.configuration.uris.tenants unless pinned
      raise TenancyConflict if Rails.configuration.uris.tenants.any?

      [ pinned ]
    end

    def declare!
      declared.map do |subdomain|
        find_by(subdomain: subdomain) || create!(subdomain: subdomain, name: subdomain.titleize)
      end
    end

    def resolve(host)
      find_by(subdomain: subdomain_for(host))
    end

    def subdomain_for(host)
      pinned || host.to_s.split(".").first
    end

    def resolve!(host)
      resolve(host) || raise(Unconfigured, "no tenant is served at #{host}")
    end

    def origin(request)
      override = ENV["URIS_PUBLIC_ORIGIN"].presence
      return request.base_url if override.nil?

      format(override, subdomain: subdomain_for(request.host))
    end

    def resource_url(request)
      "#{origin(request)}/mcp"
    end

    def issuer_url(request)
      issuer_for(subdomain_for(request.host))
    end

    def issuer_for(subdomain)
      template = ENV["MASKS_ISSUER_TEMPLATE"].presence
      raise Unconfigured, "MASKS_ISSUER_TEMPLATE is not set" if template.nil?

      format(template, subdomain: subdomain)
    end

    def redirect_url(request)
      "#{origin(request)}#{Masks::Rails::Engine.routes.url_helpers.callback_path}"
    end

    def isolated!
      return true if @isolated

      held = role_privileges

      raise Exposed, held&.fetch("rolname", nil) unless held && held["bypasses"] == false

      @isolated = true
    end

    def role_privileges
      connection.select_one(<<~SQL)
        SELECT rolname, rolsuper OR rolbypassrls AS bypasses
        FROM pg_roles WHERE rolname = current_user
      SQL
    end

    def switch(tenant)
      raise ArgumentError, "no tenant" if tenant.nil?

      isolated!

      return within_connection(tenant) { yield tenant } if Current.tenant&.id == tenant.id

      held = Current.tenant

      enter(tenant)

      begin
        yield tenant
      ensure
        enter(held)
      end
    end

    def clear!
      enter(nil)
    end

    private

      def enter(tenant)
        Current.tenant = tenant
        isolate(tenant)
      end

      def within_connection(tenant)
        return yield if connection.instance_variable_get(:@uris_tenant_id) == tenant.id

        begin
          isolate(tenant)
          yield
        ensure
          isolate(nil)
        end
      end

      def isolate(tenant)
        held = connection

        held.exec_query(
          "SELECT set_config($1, $2, false)", "tenant",
          [ TenantIsolation::SETTING, tenant&.id.to_s ]
        )

        held.instance_variable_set(:@uris_tenant_id, tenant&.id)
        held.clear_query_cache
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed
        nil
      end
  end
end
