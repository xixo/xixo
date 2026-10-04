require "test_helper"

class ServingTest < ActionDispatch::IntegrationTest
  include McpClient

  setup do
    @tenant = Tenant.create!(subdomain: "serve-#{SecureRandom.hex(4)}", name: "Serve")

    Tenant.switch(@tenant) { @store = Resource::Database.create!(key: "shelf", name: "Shelf") }

    connect!(@tenant)
  end

  test "a page someone kept is handed over as a download, in a sandbox that runs no script" do
    get content_of("page.html", "<script>fetch('/graphql')</script>", "text/html"), headers: reader

    assert_response :success
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_match(/\Asandbox;/, response.headers["Content-Security-Policy"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "an svg is a document that can run script, so it is downloaded too" do
    get content_of("mark.svg", "<svg onload='alert(1)'/>", "image/svg+xml"), headers: reader

    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_match(/\Asandbox;/, response.headers["Content-Security-Policy"])
  end

  test "a photo opens in the browser, still sandboxed" do
    get content_of("beach.jpg", "\xFF\xD8\xFF".b, "image/jpeg"), headers: reader

    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_match(/\Asandbox;/, response.headers["Content-Security-Policy"])
  end

  test "a pdf opens in the browser's viewer, which a sandbox would refuse to start" do
    get content_of("invoice.pdf", "%PDF-1.7", "application/pdf"), headers: reader

    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_nil response.headers["Content-Security-Policy"]
  end

  test "asking for a download always downloads" do
    get "#{content_of('notes.txt', 'hello', 'text/plain')}?download=1", headers: reader

    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal "hello", response.body
  end

  private

    def reader
      host_for(@tenant).merge(bearer(@tenant, [ "xixo:catalog:read" ]))
    end

    def content_of(name, body, mime)
      reference = Tenant.switch(@tenant) do
        @store.upload(name, body)
        create_feed(mime: mime, resource: @store, locator_key: name, locator: { "key" => name }).references.first
      end

      "/references/#{reference.id}/content"
    end
end
