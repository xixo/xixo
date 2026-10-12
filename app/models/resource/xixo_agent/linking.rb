class Resource
  class XixoAgent
    module Linking
      KEY = "linking".freeze
      LINKED_WITHIN = (Enrollment::LASTS + 120).seconds
      BEARER = /\ABearer ([A-Za-z0-9._~+\/=-]{16,512})\z/

      Code = Data.define(:token, :expires_at)

      module_function

      def start!(agent, minter: Enrollment.method(:mint))
        token = minter.call(agent.tenant, name: agent.name.presence || agent.key)
        at = Time.current

        agent.update!(details: agent.details.to_h.merge(KEY => { "digest" => digest(token), "at" => at.utc.iso8601 }))
        Code.new(token: token, expires_at: at + Enrollment::LASTS.seconds)
      end

      def presented(authorization)
        authorization.to_s.strip[BEARER, 1]
      end

      def pending(token)
        return nil if token.blank?

        XixoAgent.active
                 .where("resources.details -> ? ->> 'digest' = ?", KEY, digest(token))
                 .find { |agent| waiting?(agent) }
      end

      def link!(token, client_id)
        raise Resource::Refused, "that is not a client id the agent prints" unless client_id.to_s.match?(Installer::CLIENT_ID)

        XixoAgent.transaction do
          found = pending(token) || raise(Resource::Refused, "that code is not one xixo is waiting on. Get a fresh one")
          agent = XixoAgent.lock.find(found.id)
          raise Resource::Refused, "that code was used already. Get a fresh one" unless waiting?(agent) && agent.details[KEY]["digest"] == digest(token)

          if XixoAgent.where.not(id: agent.id).exists?([ "resources.details ->> 'client_id' = ?", client_id ])
            raise Resource::Refused, "another machine is linked as that client already"
          end

          agent.bound!(client_id)
          agent
        end
      end

      def waiting?(agent)
        held = agent.details.to_h[KEY]
        return false unless held.is_a?(Hash) && held["digest"].present?

        Time.iso8601(held["at"].to_s) > LINKED_WITHIN.ago
      rescue ArgumentError
        false
      end

      def expires_at(agent)
        return nil unless waiting?(agent)

        Time.iso8601(agent.details[KEY]["at"]) + Enrollment::LASTS.seconds
      end

      def digest(token)
        Digest::SHA256.hexdigest(token.to_s)
      end
    end
  end
end
