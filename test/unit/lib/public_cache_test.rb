require "test_helper"

class PublicCacheTest < ActiveSupport::TestCase
  SHORT = "public, max-age=3600".freeze

  test "a hashed asset is cached for a year and never revalidated" do
    assert_equal PublicCache::HASHED, cache_control("/vite/assets/application-D3ZpcTYO.js")
  end

  test "the service worker is revalidated on every load" do
    assert_equal "no-cache", cache_control("/sw.js")
  end

  test "an unhashed public file keeps the short cache it was served with" do
    %w[/offline.html /manifest.webmanifest /icon.png /vite/manifest.json].each do |path|
      assert_equal SHORT, cache_control(path), path
    end
  end

  test "a missing asset keeps the headers of its error" do
    assert_equal SHORT, cache_control("/vite/assets/missing.js", status: 404)
  end

  private

    def cache_control(path, status: 200)
      app = ->(_env) { [ status, { "cache-control" => SHORT }, [] ] }
      _, headers, = PublicCache.new(app, hashed_prefix: "/vite/assets/").call(Rack::MockRequest.env_for(path))
      headers["cache-control"]
    end
end
