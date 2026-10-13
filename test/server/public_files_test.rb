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
end
