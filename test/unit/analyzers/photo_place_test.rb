require "test_helper"
require_relative "../../support/geotag"

class PhotoPlaceTest < ActiveSupport::TestCase
  PHOTO = Rails.root.join("test/fixtures/corpus/image/photo.jpg")
  NAMED = { display_name: "Kensington Market, Toronto, Ontario, Canada",
            address: { neighbourhood: "Kensington Market", city: "Toronto", country: "Canada" } }.freeze

  setup do
    skip "no corpus on disk — see test/fixtures/corpus/README.md" unless PHOTO.exist? && PHOTO.dirname.join("photo.nef").exist?

    Resource::Places.spacing = 0
    @tenant = Tenant.create!(subdomain: "photo-#{SecureRandom.hex(4)}", name: "Photos")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "roll", name: "Camera roll") }
  end

  teardown { Resource::Places.spacing = nil }

  def analyzed(bytes, name: "market.jpg")
    Tenant.switch(@tenant) do
      @storage.upload(name, bytes)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analyzer = Analyzer.for(feed.reload, analysis: analysis)
      analyzer.analyze

      [ analysis.reload.steps.transform_values { |step| step["result"] }, analyzer ]
    end
  end

  def geotagged
    Geotag.jpeg(PHOTO.binread, latitude: 43.6545, longitude: -79.4005)
  end

  def tagged_raw(*tags)
    Tempfile.create([ "raw", ".nef" ], binmode: true) do |file|
      file.write(PHOTO.dirname.join("photo.nef").binread)
      file.flush
      _, status = Open3.capture2e("exiftool", "-q", "-overwrite_original", *tags, file.path)
      raise "exiftool could not tag #{file.path}" unless status.success?

      File.binread(file.path)
    end
  end

  test "a photo's coordinates are read from its exif, and a photo without them has none" do
    steps, = analyzed(geotagged)

    assert_in_delta 43.6545, steps["location"]["latitude"], 0.0001
    assert_in_delta(-79.4005, steps["location"]["longitude"], 0.0001)

    plain, = analyzed(PHOTO.binread, name: "plain.jpg")
    assert_nil plain["location"]
  end

  test "a raw photo's coordinates are read too, and a GPS block with no position in it is none" do
    steps, = analyzed(tagged_raw("-GPSLatitude=43.6545", "-GPSLatitudeRef=N", "-GPSLongitude=79.4005",
                                 "-GPSLongitudeRef=W"), name: "market.nef")

    assert_in_delta 43.6545, steps["location"]["latitude"], 0.0001
    assert_in_delta(-79.4005, steps["location"]["longitude"], 0.0001)

    empty, = analyzed(tagged_raw("-GPSVersionID=2.3.0.0"), name: "no-fix.nef")
    assert_nil empty["location"]
  end

  test "coordinates go nowhere unless a places resource has been told to name photos" do
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places", details: {}) }

    steps, = analyzed(geotagged)

    assert_not steps.key?("place")
    assert_not_requested :get, %r{nominatim}
  end

  test "a places resource told to name photos names where it was taken, and the summary hears it" do
    stub_request(:get, %r{\Ahttps://nominatim\.openstreetmap\.org/reverse}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: NAMED.to_json
    )
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places", details: { "photos" => "true" }) }

    steps, analyzer = analyzed(geotagged)

    assert_equal "Kensington Market", steps["place"]["neighbourhood"]
    assert_match(/Taken at: Kensington Market, Toronto, Ontario, Canada/, Tenant.switch(@tenant) { analyzer.summary_prompt })
    assert_requested :get, /lat=43\.6545/
  end
end
