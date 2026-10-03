require "socket"
require "tmpdir"

class FakeTailscaled
  attr_reader :path, :asked

  def initialize(state: "Running", answer: nil)
    @dir = Dir.mktmpdir("tailscaled")
    @path = File.join(@dir, "tailscaled.sock")
    @state = state
    @answer = answer
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

    def serve
      loop do
        client = @server.accept
        request = +""
        request << client.readpartial(4096) until request.include?("\r\n\r\n")
        @asked << request
        client.write(@answer || "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n#{{ BackendState: @state }.to_json}")
        client.close
      end
    end
end
