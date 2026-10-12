class Resource
  class Machine
    module Linking
      KEY = "linking".freeze
      LINKED_WITHIN = Enrollment::LASTS.seconds
      BEARER = /\ABearer ([A-Za-z0-9._~+\/=-]{16,512})\z/

      Code = Data.define(:token, :expires_at)

      module_function

      def start!(machine, minter: Enrollment.method(:mint))
        token = minter.call(machine.tenant, name: machine.name.presence || machine.key)
        at = Time.current

        machine.update!(details: machine.details.to_h.merge(KEY => { "digest" => digest(token), "at" => at.utc.iso8601 }))
        Code.new(token: token, expires_at: at + Enrollment::LASTS.seconds)
      end

      def presented(authorization)
        authorization.to_s.strip[BEARER, 1]
      end

      def pending(token)
        return nil if token.blank?

        Machine.active
                 .where("resources.details -> ? ->> 'digest' = ?", KEY, digest(token))
                 .find { |machine| waiting?(machine) }
      end

      def link!(token, client_id)
        raise Resource::Refused, "that is not a client id xixo link prints" unless client_id.to_s.match?(Installer::CLIENT_ID)

        Machine.transaction do
          found = pending(token) || raise(Resource::Refused, "that code is not one xixo is waiting on. Get a fresh one")
          machine = Machine.lock.find(found.id)
          raise Resource::Refused, "that code was used already. Get a fresh one" unless waiting?(machine) && machine.details[KEY]["digest"] == digest(token)

          if Machine.where.not(id: machine.id).exists?([ "resources.details ->> 'client_id' = ?", client_id ])
            raise Resource::Refused, "another machine is linked as that client already"
          end

          machine.bound!(client_id)
          machine
        end
      end

      def waiting?(machine)
        held = machine.details.to_h[KEY]
        return false unless held.is_a?(Hash) && held["digest"].present?

        Time.iso8601(held["at"].to_s) > LINKED_WITHIN.ago
      rescue ArgumentError
        false
      end

      def expires_at(machine)
        return nil unless waiting?(machine)

        Time.iso8601(machine.details[KEY]["at"]) + Enrollment::LASTS.seconds
      end

      def digest(token)
        Digest::SHA256.hexdigest(token.to_s)
      end
    end
  end
end
