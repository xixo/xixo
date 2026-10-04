require "test_helper"
require_relative "../../support/fake_feed_server"

module ResolvesOnce
  mattr_accessor :names, default: {}
  mattr_accessor :lookups, default: 0

  def addresses(host)
    return super unless ResolvesOnce.names.key?(host)

    ResolvesOnce.lookups += 1
    [ IPAddr.new(ResolvesOnce.names.fetch(host)) ]
  end
end

PublicAddress.singleton_class.prepend(ResolvesOnce)

class DownloadTest < ActiveSupport::TestCase
  setup do
    @server = FakeFeedServer.current
    @server.reset!
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
    ResolvesOnce.names = {}
    ResolvesOnce.lookups = 0
  end

  test "the connection goes to the address that was checked, not to a second lookup a resolver could answer differently" do
    private!

    host = "rebinds-#{SecureRandom.hex(4)}.invalid"
    ResolvesOnce.names = { host => "127.0.0.1" }
    url = @server.serve_body("/march.pdf", "pinned", content_type: "application/pdf")

    WebMock.disable!
    got = Download.of(url.sub("127.0.0.1", host))

    assert_equal "pinned", got.bytes
    assert_equal 1, ResolvesOnce.lookups
  ensure
    WebMock.enable!
  end

  test "a name that resolves to a private address is refused before it is dialled" do
    ResolvesOnce.names = { "inside.invalid" => "10.0.0.7" }

    assert_raises(Download::Blocked) { Download.of("http://inside.invalid/secrets") }
  end

  test "an address that is not public is refused before anything is dialled" do
    error = assert_raises(Download::Blocked) { Download.of("http://169.254.169.254/latest/meta-data/") }

    assert_match(/not a public address/, error.message)
  end

  test "a scheme other than http is refused" do
    assert_raises(Download::Blocked) { Download.of("file:///etc/passwd") }
    assert_raises(Download::Blocked) { Download.of("gopher://example.com/") }
  end

  # Every hop is checked, not only the one we were handed. A scheme is refused
  # whatever the address rules allow, so this holds even where private fetches do.
  test "a redirect out of http is refused rather than followed" do
    private!

    away = @server.serve_redirect("/away", "file:///etc/passwd")

    assert_raises(Download::Blocked) { Download.of(away) }
  end

  test "the bytes come back with a name taken from the address" do
    private!

    url = @server.serve_body("/papers/march.pdf", "a pretend pdf", content_type: "application/pdf")
    got = Download.of(url)

    assert_equal "a pretend pdf", got.bytes
    assert_equal "march.pdf", got.filename
    assert_equal "application/pdf", got.content_type
    assert_equal url, got.final_url
  end

  test "a content-disposition name wins over the address" do
    private!

    url = @server.serve_body(
      "/download", "a pretend pdf", content_type: "application/pdf",
      headers: { "Content-Disposition" => 'attachment; filename="March invoice.pdf"' }
    )

    assert_equal "march-invoice.pdf", Download.of(url).filename
  end

  test "a nameless address is named after what it served, so analysis knows what it is" do
    private!

    url = @server.serve_body("/", "a pretend pdf", content_type: "application/pdf")

    assert_equal ".pdf", File.extname(Download.of(url).filename)
  end

  test "a body over the ceiling is refused rather than held" do
    private!

    url = @server.serve_body("/big", "x" * 64, content_type: "application/octet-stream")

    stub_const(Download, :MAX_BYTES, 16) do
      assert_raises(Download::TooBig) { Download.of(url) }
    end
  end

  test "an answer that is not a success says what it was" do
    private!

    error = assert_raises(Download::Failed) { Download.of(@server.url_for("/nothing")) }

    assert_match(/404/, error.message)
  end

  test "a redirect is followed to a public answer" do
    private!

    @server.serve_body("/final.txt", "arrived", content_type: "text/plain")
    away = @server.serve_redirect("/start", @server.url_for("/final.txt"))

    got = Download.of(away)

    assert_equal "arrived", got.bytes
    assert_equal "final.txt", got.filename
  end

  private

    def private!
      ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    end
end
