require "net/http"

module PublicFetch
  extend ActiveSupport::Concern

  class Blocked < Resource::Failed; end

  MAX_BYTES = 5.megabytes
  MAX_REDIRECTS = 3
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15
  TOTAL_TIMEOUT = 60
  CARRIED_TO_ANOTHER_ORIGIN = %w[accept accept-encoding accept-language content-type depth user-agent].freeze

  class_methods do
    def private_fetches_allowed?
      PublicAddress.allowed?
    end
  end

  private

    def private_fetch?(_target)
      self.class.private_fetches_allowed?
    end

    def permitted!(target)
      PublicAddress.permitted!(reached(target), allow_private: private_fetch?(target), through: through)
    rescue PublicAddress::Blocked => e
      raise Blocked, "#{key}: #{e.message}"
    rescue PublicAddress::Unresolvable => e
      raise Resource::Failed, "#{key}: #{e.message}"
    end

    def pinned!(target)
      PublicAddress.pinned!(reached(target), allow_private: private_fetch?(target), through: through)
    rescue PublicAddress::Blocked => e
      raise Blocked, "#{key}: #{e.message}"
    rescue PublicAddress::Unresolvable => e
      raise Resource::Failed, "#{key}: #{e.message}"
    end

    def over_http(target, redirects: MAX_REDIRECTS, origin: nil, &build)
      pinned = pinned!(target)
      uri = pinned.uri
      origin ||= origin_of(uri)
      response = exchange(pinned) { |at| confined(build.call(at), at, origin) }

      case response
      when Net::HTTPRedirection
        raise Resource::Failed, "#{key}: too many redirects from #{target}" if redirects.zero?

        over_http(URI.join(uri, response["location"].to_s).to_s,
                  redirects: redirects - 1, origin: origin, &build)
      when Net::HTTPSuccess
        response
      else
        raise Resource::Failed, "#{key}: #{target} answered #{response.code}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Resource::Failed, "#{key}: #{e.class} fetching #{target}"
    end

    def confined(request, at, origin)
      return request if origin_of(at) == origin

      request.to_hash.each_key do |name|
        request.delete(name) unless CARRIED_TO_ANOTHER_ORIGIN.include?(name)
      end

      request
    end

    def origin_of(uri)
      [ uri.scheme, uri.hostname.to_s.downcase, uri.port ]
    end

    def exchange(pinned, &build)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      PublicAddress.start(pinned, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(build.call(pinned.uri)) { |response| drain(response, pinned.uri, started) }
      end
    end

    def drain(response, uri, started)
      held = +"".b

      response.read_body do |chunk|
        held << chunk

        raise Resource::Failed, "#{key}: #{uri.host} sent more than #{MAX_BYTES} bytes" if held.bytesize > MAX_BYTES

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > TOTAL_TIMEOUT
          raise Resource::Failed, "#{key}: #{uri.host} was still sending after #{TOTAL_TIMEOUT}s"
        end
      end

      response.body = held
    end
end
