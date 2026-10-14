require "net/http"

class Resource
  class OpenaiCompatible
    module Relaying
      extend ActiveSupport::Concern

      RELAY_SLACK = 15
      UNKNOWN_VERB = /does not know the verb/
      NOT_YET = /runs no model server of that kind|ask again later/

      module Held
        attr_writer :held

        def read_body(*) = @held
        def body = @held
      end

      def relayed_by
        return via if via.is_a?(Resource::Machine)

        held = Resource::Machine.holding([ self ])[id]
        held unless held.nil? || held.local?
      end

      private

        def relayed(machine, uri, timeout, reading, request)
          relayable!(machine, request)

          answered = machine.ask("relay", {
            "port" => uri.port, "method" => request.method, "path" => uri.request_uri,
            "body" => request.body, "authorization" => request["Authorization"], "within" => timeout
          }.compact, within: (timeout + RELAY_SLACK).seconds).to_h

          held_response(answered, reading)
        rescue Resource::Machine::Refusal => e
          raise Resource::Unusable, "#{key}: update xixo link on #{machine.key} by running the link-up command on it again" if e.message.match?(UNKNOWN_VERB)

          raise Resource::Unreachable, e.message if e.message.match?(NOT_YET)

          raise Resource::Failed, e.message
        end

        def relayable!(machine, request)
          unless machine.connected?
            raise Resource::Offline, "#{key}: #{machine.key} is offline, so xixo cannot reach the model server on it"
          end

          unless machine.offers?("models")
            raise Resource::Unusable, "#{key}: #{machine.key} does not let xixo use its model servers. Turn on models for it on its card"
          end

          return unless request["Content-Type"].to_s.start_with?("multipart/")

          raise Resource::Unusable, "#{key}: xixo link passes only text to a model server, so it cannot send audio to transcribe"
        end

        def held_response(answered, reading)
          status = answered["status"].to_i
          body = answered["body"].to_s
          raise Resource::Failed, "#{key}: the model server sent more than #{MAX_BYTES} bytes" if body.bytesize > MAX_BYTES

          response = (Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPUnknownResponse).new("1.1", status.to_s, "")
          response["Content-Type"] = answered["content_type"].to_s if answered["content_type"].present?
          response.extend(Held).held = body
          reading.from(response) << body if reading && response.is_a?(Net::HTTPSuccess)
          response
        end
    end
  end
end
