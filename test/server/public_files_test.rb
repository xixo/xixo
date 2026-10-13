require "test_helper"

class PublicFilesTest < ActionDispatch::IntegrationTest
  test "the service worker is served for revalidation, never as immutable" do
    get "/sw.js"

    assert_response :success
    assert_equal "no-cache", response.headers["cache-control"]
  end

  test "the offline page and icons keep a short cache" do
    %w[/offline.html /icon.png].each do |path|
      get path

      assert_response :success
      assert_equal "public, max-age=3600", response.headers["cache-control"], path
    end
  end

  test "the web app manifest is served as a manifest" do
    get "/manifest.webmanifest"

    assert_response :success
    assert_equal "application/manifest+json", response.media_type
  end

  test "a browser that asks for /favicon.ico gets the xixo icon" do
    get "/favicon.ico"

    assert_response :success
    assert_equal "image/vnd.microsoft.icon", response.media_type
  end
end
