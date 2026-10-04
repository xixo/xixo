require "test_helper"
require_relative "../../support/fake_feed_server"

class CurlResourceTest < ActiveSupport::TestCase
  setup do
    @server = FakeFeedServer.current
    @server.reset!

    @tenant = Tenant.create!(subdomain: "curl-#{SecureRandom.hex(4)}", name: "Curl")
    @curl = Tenant.switch(@tenant) { Resource::Curl.create!(key: "curl", name: "Curl") }
  end

  teardown { ENV.delete("XIXO_ALLOW_PRIVATE_FETCH") }

  test "a page is read as its title and the text a person would see" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    url = @server.serve_body("/story", <<~HTML, content_type: "text/html; charset=utf-8")
      <html><head><title>Show HN: xixo</title><style>body { color: red }</style></head>
      <body><nav>home | new | past</nav><h1>Show HN: xixo</h1>
      <p>A catalog of everything you own.</p><script>track()</script></body></html>
    HTML

    got = Tenant.switch(@tenant) { @curl.command("get", url: url) }

    assert_equal 200, got[:status]
    assert_equal "text/html", got[:content_type]
    assert_equal "Show HN: xixo", got[:title]
    assert_match(/A catalog of everything you own/, got[:text])
    assert_no_match(/track\(\)|color: red|home \| new/, got[:text])
  end

  test "json comes back as it was served" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    url = @server.serve_body("/api", %({"hits":[{"title":"xixo"}]}), content_type: "application/json")

    got = Tenant.switch(@tenant) { @curl.command("get", url: url) }

    assert_equal %({"hits":[{"title":"xixo"}]}), got[:text]
  end

  test "bytes that are not text are described rather than read" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    url = @server.serve_body("/logo.png", "\x89PNG\r\n\x1A\n\x00\x00".b, content_type: "image/png")

    got = Tenant.switch(@tenant) { @curl.command("get", url: url) }

    assert_nil got[:text]
    assert_equal "image/png", got[:content_type]
  end

  test "a body past the cap is refused rather than handed on" do
    stub_request(:get, "https://huge.example.test/").to_return(body: "x" * (PublicFetch::MAX_BYTES + 1))

    error = assert_raises(Resource::Failed) do
      Tenant.switch(@tenant) { @curl.command("get", url: "https://huge.example.test/") }
    end

    assert_match(/more than #{PublicFetch::MAX_BYTES} bytes/, error.message)
  end

  test "a server trickling its answer is stopped once the whole fetch runs past its time" do
    stub_request(:get, "https://slow.example.test/").to_return(body: "a" * 64_000)
    clock = [ 0.0 ]
    Process.singleton_class.alias_method(:unstopped_clock, :clock_gettime)
    Process.define_singleton_method(:clock_gettime) do |*args|
      args.first == Process::CLOCK_MONOTONIC ? clock[0] += PublicFetch::TOTAL_TIMEOUT + 1 : unstopped_clock(*args)
    end

    error = assert_raises(Resource::Failed) do
      Tenant.switch(@tenant) { @curl.command("get", url: "https://slow.example.test/") }
    end

    assert_match(/still sending after #{PublicFetch::TOTAL_TIMEOUT}s/, error.message)
  ensure
    Process.singleton_class.alias_method(:clock_gettime, :unstopped_clock)
  end

  test "a private or local address is refused before anything is dialled" do
    assert_raises(PublicFetch::Blocked) do
      Tenant.switch(@tenant) { @curl.command("get", url: "http://169.254.169.254/latest/meta-data/") }
    end

    assert_raises(PublicFetch::Blocked) do
      Tenant.switch(@tenant) { @curl.command("get", url: "file:///etc/passwd") }
    end
  end

  test "it is attached from the app with nothing to fill in" do
    assert_equal [], Resource::Curl.attaching[:fields]
    assert_includes Resource.find_sti_class("curl").serves, "fetch"
  end
end
