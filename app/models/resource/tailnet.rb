require "socket"

class Resource
  class Tailnet < Resource
    RANGES = %w[100.64.0.0/10 fd7a:115c:a1e0::/48].map { |block| IPAddr.new(block) }.freeze
    LOCAL_API = "local-tailscaled.sock".freeze
    TIMEOUT = 5
    MAX_STATUS = 8.megabytes

    serves :transport

    def self.declared_only?
      true
    end

    def self.socket
      ENV.fetch("XIXO_TAILSCALE_SOCKET", "")
    end

    def self.declared
      socket.present? ? { "tailnet" => { "type" => sti_name, "name" => "Tailnet" } } : {}
    end

    def covers
      RANGES
    end

    def reach!(target)
      target
    end

    def check!
      state = status["BackendState"]
      return true if state == "Running"

      raise Resource::Failed, "#{key}: tailscaled is #{state.presence || 'in no state it names'}"
    end

    def status
      JSON.parse(local("/localapi/v0/status"))
    rescue JSON::ParserError
      raise Resource::Failed, "#{key}: tailscaled answered something that is not JSON"
    end

    private

      def local(path)
        socket = self.class.socket
        raise Resource::Unusable, "#{key}: XIXO_TAILSCALE_SOCKET names no tailscaled socket" if socket.blank?

        UNIXSocket.open(socket) do |io|
          io.write("GET #{path} HTTP/1.0\r\nHost: #{LOCAL_API}\r\nSec-Tailscale: localapi\r\n\r\n")
          answered(drained(io), path)
        end
      rescue SystemCallError, IOError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching tailscaled at #{socket}"
      end

      def drained(io)
        held = +"".b

        loop do
          raise Resource::Failed, "#{key}: tailscaled did not answer in #{TIMEOUT}s" unless io.wait_readable(TIMEOUT)

          chunk = io.read_nonblock(64.kilobytes, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable

          held << chunk
          raise Resource::Failed, "#{key}: tailscaled sent more than #{MAX_STATUS} bytes" if held.bytesize > MAX_STATUS
        end

        held
      end

      def answered(raw, path)
        head, body = raw.split("\r\n\r\n", 2)
        code = head.to_s[%r{\AHTTP/\d\.\d (\d{3})}, 1]
        return body.to_s if code == "200"

        raise Resource::Failed, "#{key}: tailscaled answered #{code || 'nothing'} for #{path}"
      end
  end
end
