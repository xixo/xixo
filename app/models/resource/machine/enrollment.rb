class Resource
  class Machine
    module Enrollment
      LASTS = 600

      module_function

      def mint(tenant, name:)
        credentials = tenant.masks_credentials
        raise Resource::Failed, "this tenant is not connected to masks, so it cannot enroll a machine" if credentials.nil?

        answered = Masks::Client::HTTP.post_form(
          endpoint(tenant),
          [ [ "scope", Grant::MACHINE ], [ "client_name", name.to_s ], [ "expires_in", LASTS.to_s ] ],
          "Authorization" => basic(credentials)
        )

        answered.to_h["initial_access_token"].presence ||
          raise(Resource::Failed, "masks answered an enrollment without a token")
      rescue Masks::Client::Error => e
        raise Resource::Failed, "masks would not enroll the machine: #{e.message}"
      end

      def revoke(tenant, client_id)
        credentials = tenant.masks_credentials
        raise Resource::Failed, "this tenant is not connected to masks, so it cannot cut a machine off" if credentials.nil?

        Masks::Client::HTTP.delete("#{endpoint(tenant)}/#{URI.encode_www_form_component(client_id)}",
                                   "Authorization" => basic(credentials))
        true
      rescue Masks::Client::Rejected => e
        return true if e.status == 404

        raise Resource::Failed, "masks would not unenroll the machine: #{e.message}"
      rescue Masks::Client::Error => e
        raise Resource::Failed, "masks could not be reached to unenroll the machine: #{e.message}"
      end

      def endpoint(tenant)
        issuer = Masks::Client::Issuer.resolve(tenant.issuer)

        issuer.discovery["enrollment_endpoint"].presence || "#{issuer.url}/enrollments"
      end

      def basic(credentials)
        pair = [ credentials[:client_id], credentials[:client_secret] ].map { |part| URI.encode_www_form_component(part) }

        "Basic #{Base64.strict_encode64(pair.join(':'))}"
      end
    end
  end
end
