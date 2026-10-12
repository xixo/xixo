module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :tenant, :grant, :machine, :client_id

    attr_reader :expires_at

    def connect
      self.tenant = Tenant.resolve(request.host) || reject_unauthorized_connection

      Tenant.switch(tenant) do
        if request.authorization.present?
          held = enrolled || reject_unauthorized_connection
          self.machine = held.agent
          self.client_id = held.claims.client_id
        else
          self.grant = granted || reject_unauthorized_connection
        end
      end
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    private

      def granted
        tokens = Masks::Client::Tokens.from_h(masks_session)
        return nil if tokens.nil? || tokens.access_token.blank? || tokens.expired?

        Grant.new(
          tenant: tenant,
          claims: resource.authenticate("Bearer #{tokens.access_token}")
        )
      rescue Masks::Client::Error, Grant::Denied, Tenant::Unconfigured
        nil
      end

      def enrolled
        held = Resource::XixoAgent::Caller.from(request, path: "/cable")
        return nil if held.nil?

        @expires_at = held.expires_at
        held
      end

      def masks_session
        held = request.session[Masks::Rails.config.session_key]

        held.is_a?(Hash) ? held : nil
      end

      def resource
        ResourceServer.for(request)
      end
  end
end
