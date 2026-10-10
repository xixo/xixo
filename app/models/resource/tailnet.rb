require "socket"

class Resource
  class Tailnet < Resource
    RANGES = %w[100.64.0.0/10 fd7a:115c:a1e0::/48].map { |block| IPAddr.new(block) }.freeze
    LOCAL_API = "local-tailscaled.sock".freeze
    TIMEOUT = 5
    MAX_STATUS = 8.megabytes
    MAX_NODES = 256
    MAX_PROBED = 32
    PROBE_TIMEOUT = 0.5
    NEVER = Time.utc(1971)
    SERVICES = [
      { "name" => "ollama", "port" => 11_434, "type" => "openai-compatible" },
      { "name" => "lm-studio", "port" => 1234, "type" => "openai-compatible" },
      { "name" => "imaps", "port" => 993, "type" => "imap" }
    ].freeze

    serves :transport

    def self.declared_only?
      true
    end

    def self.socket
      ENV.fetch("XIXO_TAILSCALE_SOCKET", "")
    end

    def self.command_schema
      { discover: {} }
    end

    def self.listening?(address, port)
      Socket.tcp(address, port, connect_timeout: PROBE_TIMEOUT).close
      true
    rescue SystemCallError, IOError, SocketError
      false
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

    def offline_peer(host)
      named = Node.normalized(host)
      return if named.nil?

      nodes.find { |node| !node["online"] && Node.answers_to?(node, named) }
    end

    def discovered(services: false)
      found = nodes
      services ? probed(found) : found
    end

    def command_discover
      { "transport" => key, "nodes" => discovered(services: true) }
    end

    def nodes
      peers = status["Peer"]
      return [] unless peers.is_a?(Hash)

      peers.values.first(MAX_NODES).filter_map { |peer| Node.from(peer, covers) }
           .sort_by { |node| [ node["online"] ? 0 : 1, node["host_name"].to_s ] }
    end

    def status
      JSON.parse(local("/localapi/v0/status"))
    rescue JSON::ParserError
      raise Resource::Failed, "#{key}: tailscaled answered something that is not JSON"
    end

    private

      def probed(found)
        asked = found.select { |node| node["online"] && node["addresses"].any? }.first(MAX_PROBED)
        knocks = asked.flat_map { |node| SERVICES.map { |service| [ node, service ] } }

        heard = knocks.map do |node, service|
          Thread.new { [ node, service ] if self.class.listening?(node["addresses"].first, service["port"]) }
        end.filter_map(&:value)

        found.map do |node|
          node.merge("services" => heard.select { |held, _| held.equal?(node) }.map { |_, service| offered(node, service) })
        end
      end

      def offered(node, service)
        address = Resource.find_sti_class(service["type"]).address_on(node["addresses"].first, port: service["port"])
        service.merge("address" => address)
      end

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
