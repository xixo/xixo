class Resource
  class Machine
    Caller = Data.define(:machine, :claims) do
      def self.from(request, path:)
        claims = ResourceServer.for(request).authenticate(
          request.authorization, proof: request.headers["DPoP"], method: request.request_method,
                                 url: "#{Tenant.origin(request)}#{path}"
        )
        return nil unless machine?(claims)

        Grant.new(tenant: Current.tenant, claims: claims)
        machine = Machine.enrolled(claims.client_id)
        return new(machine: machine, claims: claims) if machine

        EnrollLocalLinkJob.perform_later if EnrollLocalLinkJob.handoff
        nil
      rescue Masks::Client::Error, Grant::Denied, Tenant::Unconfigured => e
        Rails.logger.info "a machine was not let in: #{e.message}"
        nil
      end

      def self.machine?(claims)
        claims["cnf"].is_a?(Hash) && claims["cnf"]["jkt"].present? &&
          claims.scopes.include?(Grant::MACHINE) &&
          claims.client_id.present? &&
          claims.subject == claims.client_id
      end

      def expires_at = claims.expires_at
    end
  end
end
