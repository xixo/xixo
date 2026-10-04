require "test_helper"
require_relative "../../support/fake_feed_server"

class SnapshotTest < ActiveSupport::TestCase
  PAGE = <<~HTML.freeze
    <!doctype html>
    <html><head><title>A page about pelicans</title></head>
    <body style="margin:0;font:16px sans-serif">
      <h1>Pelicans</h1>
      <p>Rather a lot about pelicans.</p>
      <div style="height:2400px"></div>
    </body></html>
  HTML

  TALL = <<~HTML.freeze
    <!doctype html>
    <html><head><title>A very long page</title></head>
    <body style="margin:0"><div style="height:26000px"></div></body></html>
  HTML

  setup do
    @server = FakeFeedServer.current
    @server.reset!
    @url = @server.serve_body("/page.html", PAGE, content_type: "text/html")
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a non-http scheme is refused before a browser is started" do
    error = assert_raises(Snapshot::Blocked) { Snapshot.of("file:///etc/passwd") }

    assert_match(/not an http or https URL/, error.message)
  end

  test "a private address is refused unless fetching them is allowed" do
    error = assert_raises(Snapshot::Blocked) { Snapshot.of(@url) }

    assert_match(/not a public address/, error.message)
  end

  test "the guard on every request refuses a scheme whatever the address rules say" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    snapshot = Snapshot.new(@url)

    assert snapshot.permits?("http://127.0.0.1:9000/style.css")
    assert snapshot.permits?("data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==")

    refute snapshot.permits?("file:///etc/passwd")
    refute snapshot.permits?("chrome://settings")
    refute snapshot.permits?("view-source:http://127.0.0.1:9000/")
  end

  test "the address rules still apply to requests once private fetches are not allowed" do
    snapshot = Snapshot.new("https://8.8.8.8/")

    refute snapshot.permits?("http://169.254.169.254/latest/meta-data/")
    assert snapshot.permits?("https://8.8.8.8/style.css")
  end

  test "a page is captured whole, below the fold as well" do
    rendering do
      capture = Snapshot.of(@url)

      assert_equal @url, capture.url
      assert_equal "A page about pelicans", capture.title
      assert_match(/Pelicans/, capture.text)
      assert_match(/Rather a lot about pelicans/, capture.text)

      assert_equal "\x89PNG\r\n\x1A\n".b, capture.png.byteslice(0, 8)

      width, height = dimensions(capture.png)
      assert_equal 1280, width
      assert_operator height, :>, Snapshot::HEIGHT
      assert_equal height, capture.height
    end
  end

  test "asking for the viewport alone stops at the fold" do
    rendering do
      capture = Snapshot.of(@url, full_page: false)

      assert_equal Snapshot::HEIGHT, capture.height
      assert_equal [ 1280, Snapshot::HEIGHT ], dimensions(capture.png)
    end
  end

  test "a page taller than the ceiling is cut off at it rather than rendered whole" do
    rendering do
      tall = @server.serve_body("/tall.html", TALL, content_type: "text/html")
      capture = Snapshot.of(tall)

      assert_equal Snapshot::MAX_HEIGHT, capture.height
      assert_equal Snapshot::MAX_HEIGHT, dimensions(capture.png).last
    end
  end

  test "the width is clamped to something a browser can lay out" do
    rendering do
      capture = Snapshot.of(@url, width: 99_999, full_page: false)

      assert_equal Snapshot::WIDTHS.max, capture.width
      assert_equal Snapshot::WIDTHS.max, dimensions(capture.png).first
    end
  end

  test "chrome is started with same-origin policy and site isolation left on" do
    flags = Snapshot.flags

    refute flags.key?("disable-web-security")
    refute flags.key?("disable-site-isolation-trials")
    refute_match(/site-per-process|IsolateOrigins/, flags["disable-features"].to_s)
    assert flags.key?("headless")
  end

  private

    def rendering
      skip "no browser to render with" unless Snapshot.available?

      ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
      yield
    end

    def dimensions(png)
      png.byteslice(16, 8).unpack("N2")
    end
end
