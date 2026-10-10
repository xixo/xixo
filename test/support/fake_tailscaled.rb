require "socket"
require "tmpdir"

class FakeTailscaled
  attr_reader :path, :asked

  def self.peer(host, address, online: true, last_seen: nil)
    {
      "ID" => "n#{SecureRandom.hex(4)}", "PublicKey" => "nodekey:#{SecureRandom.hex(32)}", "HostName" => host,
      "DNSName" => "#{host}.tail0000.ts.net.", "OS" => "linux", "UserID" => 42, "TailscaleIPs" => [ address, "fd7a:115c:a1e0::#{address.split('.').last}" ],
      "Online" => online, "LastSeen" => last_seen&.utc&.iso8601 || "0001-01-01T00:00:00Z", "Relay" => "tor",
      "PeerAPIURL" => [ "http://#{address}:41641" ], "Tags" => [ "tag:server" ], "KeyExpiry" => "2027-01-01T00:00:00Z"
    }
  end

  attr_accessor :peers

  def initialize(state: "Running", answer: nil, peers: [])
    @dir = Dir.mktmpdir("tailscaled")
    @path = File.join(@dir, "tailscaled.sock")
    @state = state
    @answer = answer
    @peers = peers
    @asked = Queue.new
    @server = UNIXServer.new(@path)
    @thread = Thread.new { serve }
  end

  def stop
    @thread.kill
    @server.close
    FileUtils.remove_entry(@dir)
  end

  private

    def status
      {
        "BackendState" => @state,
        "Self" => { "HostName" => "xixo", "PublicKey" => "nodekey:self", "TailscaleIPs" => [ "100.64.0.1" ], "Online" => true },
        "Peer" => @peers.to_h { |peer| [ peer["PublicKey"], peer ] }
      }
    end

    def serve
      loop do
        client = @server.accept
        request = +""
        request << client.readpartial(4096) until request.include?("\r\n\r\n")
        @asked << request
        client.write(@answer || "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n#{status.to_json}")
        client.close
      end
    end
end
