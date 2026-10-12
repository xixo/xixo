module ApplicationCable
  class Connection < ActionCable::Connection::Base
    include Masks::Rails::Authentication

    UNKNOWN_MACHINE = "unknown_machine".freeze

    identified_by :tenant, :grant, :machine, :client_id

    attr_reader :expires_at

    def connect
      self.tenant = Tenant.resolve(request.host) || reject_unauthorized_connection

      Tenant.switch(tenant) do
        if request.authorization.present?
          held = enrolled
          self.machine = held.machine
          self.client_id = held.client_id
        else
          self.grant = granted || reject_unauthorized_connection
        end
      end
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def session
      request.session
    end

    def refuse(reason)
      close(reason: reason, reconnect: false) if websocket&.alive?
      reject_unauthorized_connection
    end

    private

      def granted
        return nil unless masks_signed_in?

        Grant.new(tenant: tenant, claims: resource.authenticate("Bearer #{masks_tokens.access_token}"))
      rescue Masks::Client::Error, Grant::Denied, Tenant::Unconfigured
        nil
      end

      def enrolled
        held = Resource::Machine::Caller.from(request, path: "/cable") || reject_unauthorized_connection
        return unenrolled(held) if held.machine.nil?

        @expires_at = held.expires_at
        held
      end

      def unenrolled(held)
        refuse(UNKNOWN_MACHINE) unless EnrollLocalLinkJob.awaits?(tenant, held.client_id)

        EnrollLocalLinkJob.perform_later(tenant.subdomain)
        reject_unauthorized_connection
      end

      def resource
        ResourceServer.for(request)
      end
  end
end
