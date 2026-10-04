require "test_helper"
require_relative "../../support/fake_feed_server"

module EgressResolves
  mattr_accessor :names, default: {}
  mattr_accessor :refused, default: []
  mattr_accessor :asked, default: []

  def addresses(host)
    return super unless EgressResolves.names.key?(host)

    EgressResolves.asked << host
    [ IPAddr.new(EgressResolves.names.fetch(host)) ]
  end

  def address_for!(host, **options)
    raise PublicAddress::Blocked, "#{host} is refused here" if EgressResolves.refused.include?(host)

    super
  end
end

PublicAddress.singleton_class.prepend(EgressResolves)

class SnapshotEgressTest < ActiveSupport::TestCase
  setup do
    @server = FakeFeedServer.current
    @server.reset!
    @url = @server.serve_body("/page.html", "pelicans", content_type: "text/plain")
    @egress = Snapshot::Egress.new.start
  end

  teardown do
    @egress.stop
    EgressResolves.names = {}
    EgressResolves.refused = []
    EgressResolves.asked = []
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a tunnel to a private address is refused" do
    assert_match(%r{\AHTTP/1.1 403}, asked("CONNECT 169.254.169.254:80 HTTP/1.1\r\nHost: 169.254.169.254:80\r\n\r\n"))
    assert_match(%r{\AHTTP/1.1 403}, asked("CONNECT localhost:#{@server.port} HTTP/1.1\r\n\r\n"))
    assert_match(%r{\AHTTP/1.1 403}, asked("CONNECT [::1]:#{@server.port} HTTP/1.1\r\n\r\n"))
  end

  test "a plain request to a private address is refused" do
    assert_match(%r{\AHTTP/1.1 403}, asked("GET #{@url} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    assert_match(%r{\AHTTP/1.1 403}, asked("GET http://169.254.169.254/latest/meta-data/ HTTP/1.1\r\n\r\n"))
  end

  test "anything but a tunnel or a plain http request is refused" do
    assert_match(%r{\AHTTP/1.1 400}, asked("GET ftp://example.com/ HTTP/1.1\r\n\r\n"))
    assert_match(%r{\AHTTP/1.1 400}, asked("GET /relative HTTP/1.1\r\n\r\n"))
  end

  test "a name is resolved once, by the egress, and the connection goes where it was vetted" do
    EgressResolves.names = { "rebound.example" => "127.0.0.1" }

    assert_match(%r{\AHTTP/1.1 403}, asked("CONNECT rebound.example:#{@server.port} HTTP/1.1\r\n\r\n"))

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    answer = asked("GET http://rebound.example:#{@server.port}/page.html HTTP/1.1\r\nHost: rebound.example\r\n\r\n")

    assert_match(/pelicans\z/, answer)
    assert_equal %w[rebound.example rebound.example], EgressResolves.asked
  end

  test "once private addresses are allowed, a request is forwarded without what was meant for the proxy" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    answer = asked("GET #{@url} HTTP/1.1\r\nHost: 127.0.0.1:#{@server.port}\r\nProxy-Authorization: Basic c2VjcmV0\r\n\r\n")

    assert_match(%r{\AHTTP/1.[01] 200}, answer)
    assert_match(/pelicans\z/, answer)
  end

  test "once private addresses are allowed, a tunnel carries bytes both ways" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    socket = TCPSocket.new("127.0.0.1", @egress.port)
    socket.write("CONNECT 127.0.0.1:#{@server.port} HTTP/1.1\r\n\r\n")

    assert_equal "HTTP/1.1 200 Connection Established\r\n\r\n", socket.readpartial(1024)

    socket.write("GET /page.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")

    assert_match(/pelicans\z/, drain(socket))
  ensure
    socket&.close
  end

  test "chrome is sent through the egress for every address, loopback included" do
    flags = Snapshot.flags(egress: @egress)

    assert_equal @egress.address, flags["proxy-server"]
    assert_equal "<-loopback>", flags["proxy-bypass-list"]
    assert_equal "disable_non_proxied_udp", flags["force-webrtc-ip-handling-policy"]
  end

  test "a page cannot open a websocket to an address the egress refuses" do
    skip "no browser to render with" unless Snapshot.available?

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    listener = TCPServer.new("127.0.0.1", 0)
    reached = Concurrent::AtomicBoolean.new
    watcher = Thread.new do
      listener.accept
      reached.make_true
    rescue IOError
      nil
    end

    @server.serve_body("/socket.html", <<~HTML, content_type: "text/html")
      <!doctype html><html><head><title>socket</title></head><body>
      <script>new WebSocket("ws://127.0.0.1:#{listener.addr[1]}/");</script></body></html>
    HTML

    EgressResolves.refused = [ "127.0.0.1" ]
    capture = Snapshot.of("http://localhost:#{@server.port}/socket.html", full_page: false)

    assert_equal "socket", capture.title
    sleep 0.5
    assert_not reached.true?, "the page reached a listener the egress refused"
  ensure
    watcher&.kill
    listener&.close
  end

  private

    def asked(request)
      socket = TCPSocket.new("127.0.0.1", @egress.port)
      socket.write(request)
      drain(socket)
    ensure
      socket&.close
    end

    def drain(socket)
      held = +""
      loop do
        break unless socket.wait_readable(5)

        held << socket.readpartial(4096)
      end
      held
    rescue EOFError, Errno::ECONNRESET
      held
    end
end
