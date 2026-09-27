require "net/http"
require "json"

class Resource
  class Api < Resource
    class Gone < Resource::Failed; end
    class Expired < Resource::Failed; end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30
    MAX_BYTES = 8.megabytes
    MAX_TEXT = 100_000
    PAGE = 100

    class << self
      def api
        raise NotImplementedError, "#{name} names no API"
      end

      def service
        name.demodulize
      end

      def token_field(label, help: nil, placeholder: nil)
        field("token", label, required: true, secret: true, help: help, placeholder: placeholder)
      end
    end

    def token
      credentials["token"].presence ||
        raise(Resource::Unusable, "#{key} carries no token — attach it again")
    end

    def token_expired!
    end

    def api_get(path, **query)
      answer(:get, path, query: query)
    end

    def api_post(path, body, **query)
      answer(:post, path, query: query, body: body)
    end

    def api_bytes(path, max_bytes: MAX_BYTES, **query)
      answer(:get, path, query: query, bytes: max_bytes)
    end

    private

      def headers
        {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/json",
          "User-Agent" => "uris"
        }
      end

      def endpoint(path, query)
        base = path.start_with?("http") ? path : "#{self.class.api}#{path}"
        wanted = query.compact
        uri = URI.parse(wanted.empty? ? base : "#{base}#{base.include?('?') ? '&' : '?'}#{URI.encode_www_form(wanted)}")

        unless uri.is_a?(URI::HTTPS) && uri.host == URI.parse(self.class.api).host
          raise Resource::Unusable, "#{key}: #{uri} is not #{self.class.service}"
        end

        uri
      end

      def answer(verb, path, query: {}, body: nil, bytes: nil, retried: false)
        uri = endpoint(path, query)
        response = exchange(uri, verb, body)

        case response
        when Net::HTTPUnauthorized
          if !retried && token_expired!
            return answer(verb, path, query: query, body: body, bytes: bytes, retried: true)
          end

          raise Resource::Unusable, "#{key}: #{self.class.service} refused the token"
        when Net::HTTPNotFound
          raise Gone, "#{key}: #{self.class.service} has no #{uri.path}"
        when Net::HTTPGone
          raise Expired, "#{key}: #{self.class.service} no longer answers #{uri.path} — #{refused(response)}"
        when Net::HTTPTooManyRequests, Net::HTTPForbidden
          raise Resource::Failed, "#{key}: #{self.class.service} is rate limiting — #{refused(response)}"
        when Net::HTTPServerError
          raise Resource::Failed, "#{key}: #{self.class.service} answered #{response.code}"
        when Net::HTTPSuccess
          bytes ? bounded(response, bytes) : parsed(response)
        else
          raise Resource::Unusable, "#{key}: #{self.class.service} answered #{response.code} — #{refused(response)}"
        end
      end

      def parsed(response)
        JSON.parse(bounded(response).presence || "{}")
      rescue JSON::ParserError
        raise Resource::Failed, "#{key}: #{self.class.service} did not answer with JSON"
      end

      def bounded(response, limit = MAX_BYTES)
        held = response.body.to_s

        raise Resource::Failed, "#{key}: more than #{limit} bytes" if held.bytesize > limit

        held
      end

      def refused(response)
        body = JSON.parse(response.body.to_s[0, 4096])
        [ body["message"], body["error"], body.dig("error", "message") ]
          .find { |said| said.is_a?(String) && said.present? } || "no reason given"
      rescue JSON::ParserError
        response.body.to_s.squish.truncate(120).presence || "no reason given"
      end

      def exchange(uri, verb, body)
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(built(uri, verb, body))
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Resource::Failed, "#{key}: #{uri.host} did not answer in #{READ_TIMEOUT}s"
      rescue Net::HTTPBadResponse, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching #{uri.host}"
      end

      def built(uri, verb, body)
        return Net::HTTP::Get.new(uri, headers) if verb == :get

        Net::HTTP::Post.new(uri, headers.merge("Content-Type" => "application/json")).tap do |request|
          request.body = JSON.generate(body || {})
        end
      end

      def flattened(*parts)
        parts.flatten.compact_blank.join("\n\n").strip.truncate(MAX_TEXT)
      end
  end
end
