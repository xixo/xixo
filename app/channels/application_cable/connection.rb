module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :tenant, :grant, :machine

    attr_reader :expires_at

    def connect
      self.tenant = Tenant.resolve(request.host) || reject_unauthorized_connection

      Tenant.switch(tenant) do
        if request.authorization.present?
          self.machine = enrolled || reject_unauthorized_connection
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
        claims = resource.authenticate(request.authorization, proof: request.headers["DPoP"],
                                                              method: "GET", url: "#{Tenant.origin(request)}/cable")
        return nil unless machine_claims?(claims)

        Grant.new(tenant: tenant, claims: claims)
        @expires_at = claims.expires_at
        Resource::XixoAgent.enrolled(claims.client_id)
      rescue Masks::Client::Error, Grant::Denied, Tenant::Unconfigured => e
        logger.info "an agent was not let in: #{e.message}"
        nil
      end

      def machine_claims?(claims)
        claims["cnf"].is_a?(Hash) && claims["cnf"]["jkt"].present? &&
          claims.scopes.include?(Grant::MACHINE) &&
          claims.client_id.present? &&
          claims.subject == claims.client_id
      end

      def masks_session
        session = cookies.encrypted[Rails.application.config.session_options[:key]]

        session.is_a?(Hash) ? session[Masks::Rails.config.session_key] : nil
      end

      def resource
        Masks::Rails.config.resource_server_for(request)
      end
  end
end
