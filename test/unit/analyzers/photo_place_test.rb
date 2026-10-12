require "test_helper"

class PhotoPlaceTest < ActiveSupport::TestCase
  NAMED = { display_name: "Kensington Market, Toronto, Ontario, Canada",
            address: { neighbourhood: "Kensington Market", city: "Toronto", country: "Canada" } }.freeze

  setup do
    Resource::Places.spacing = 0
    @tenant = Tenant.create!(subdomain: "photo-#{SecureRandom.hex(4)}", name: "Photos")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "roll", name: "Camera roll") }
  end

  teardown { Resource::Places.spacing = nil }

  def analyzed(location, name: "market.jpg")
    FakeAgent.script = lambda do |*|
      FakeAgent.extracted({ "dimensions" => { "width" => 640, "height" => 480 }, "location" => location }, extractor: "image")
    end

    Tenant.switch(@tenant) do
      @storage.upload(name, "\xFF\xD8 a photo".b)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analyzer = Analyzer.for(feed.reload, analysis: analysis)
      analyzer.extract!
      analyzer.analyze

      [ analysis.reload.steps.transform_values { |step| step["result"] }, analyzer ]
    end
  end

  test "coordinates go nowhere unless a places resource has been told to name photos" do
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places", details: {}) }

    steps, = analyzed({ "latitude" => 43.6545, "longitude" => -79.4005 })

    assert_not steps.key?("place")
    assert_not_requested :get, %r{nominatim}
  end

  test "a places resource told to name photos names where it was taken, and the summary hears it" do
    stub_request(:get, %r{\Ahttps://nominatim\.openstreetmap\.org/reverse}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: NAMED.to_json
    )
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places", details: { "photos" => "true" }) }

    steps, analyzer = analyzed({ "latitude" => 43.6545, "longitude" => -79.4005 })

    assert_equal "Kensington Market", steps["place"]["neighbourhood"]
    assert_match(/Taken at: Kensington Market, Toronto, Ontario, Canada/, Tenant.switch(@tenant) { analyzer.summary_prompt })
    assert_requested :get, /lat=43\.6545/
  end

  test "a location that is not a pair of numbers is not looked up" do
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places", details: { "photos" => "true" }) }

    steps, = analyzed({ "latitude" => "43.6545; drop table", "longitude" => [ 1 ] })

    assert_not steps.key?("place")
    assert_not_requested :get, %r{nominatim}
  end
end
