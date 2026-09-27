require "test_helper"

class PlacesResourceTest < ActiveSupport::TestCase
  FOUND = [
    { name: "Kensington Market", display_name: "Kensington Market, Toronto, Ontario, Canada", category: "place",
      type: "neighbourhood", lat: "43.6545", lon: "-79.4005",
      address: { neighbourhood: "Kensington Market", city: "Toronto", state: "Ontario", country: "Canada" } }
  ].freeze

  NEARBY = { elements: [
    { type: "node", lat: 43.6560, lon: -79.4010, tags: { name: "Far Cafe", amenity: "cafe" } },
    { type: "way", center: { lat: 43.6546, lon: -79.4006 },
      tags: { name: "Near Cafe", amenity: "cafe", "addr:housenumber" => "12", "addr:street" => "Baldwin St",
              opening_hours: "Mo-Su 08:00-18:00" } }
  ] }.freeze

  setup do
    Resource::Places.spacing = 0
    @tenant = Tenant.create!(subdomain: "geo-#{SecureRandom.hex(4)}", name: "Places")
  end

  teardown { Resource::Places.spacing = nil }

  def places(**details)
    Tenant.switch(@tenant) { Resource::Places.create!(key: "places-#{SecureRandom.hex(3)}", name: "Places", details: details) }
  end

  def json(body)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
  end

  test "a place is found by name, with its address said the way a person would" do
    stub_request(:get, %r{\Ahttps://nominatim\.openstreetmap\.org/search}).to_return(json(FOUND))

    found = Tenant.switch(@tenant) { places.command("find", query: "kensington market") }[:found].first

    assert_equal "Kensington Market, Toronto, Ontario, Canada", found[:address]
    assert_equal "Toronto", found[:city]
    assert_in_delta 43.6545, found[:latitude], 0.0001
    assert_requested :get, /q=kensington(%20|\+)market/
    assert_requested(:get, %r{nominatim}) { |request| request.headers["User-Agent"].include?("uris") }
  end

  test "coordinates are named, and what are not coordinates is refused before anything is asked" do
    stub_request(:get, %r{/reverse}).to_return(json(FOUND.first))

    Tenant.switch(@tenant) do
      held = places

      assert_equal "Kensington Market", held.reverse("43.6545", "-79.4005")[:neighbourhood]
      assert_raises(ArgumentError) { held.reverse("north", "west") }
      assert_raises(ArgumentError) { held.reverse(91, 0) }
    end

    assert_requested :get, %r{/reverse}, times: 1
  end

  test "what is nearby comes back nearest first, found around a place by name" do
    stub_request(:get, %r{/search}).to_return(json(FOUND))
    stub_request(:post, "https://overpass-api.de/api/interpreter").to_return(json(NEARBY))

    told = Tenant.switch(@tenant) { places.nearby("Cafe", place: "kensington market", radius: 99_999) }

    assert_equal %w[Near\ Cafe Far\ Cafe], told[:found].map { |spot| spot[:name] }
    assert_equal "12 Baldwin St", told[:found].first[:address]
    assert_operator told[:found].first[:metres], :<, told[:found].last[:metres]
    assert_equal 5_000, told[:around][:radius]
    assert_requested(:post, %r{overpass}) { |request| URI.decode_www_form(request.body).to_h["data"].include?('~"^cafe$"') }
  end

  test "a kind that could reach into the query is refused before anything is asked" do
    Tenant.switch(@tenant) do
      held = places

      [ 'cafe"];out;', "cafe|bar", "", "Café" ].each do |kind|
        assert_raises(ArgumentError) { held.nearby(kind, latitude: 43.65, longitude: -79.4) }
      end
    end

    assert_not_requested :post, %r{overpass}
  end

  test "a server of your own is used instead, and a server that is not an address is refused" do
    stub_request(:get, %r{\Ahttps://geo\.example\.test/search}).to_return(json(FOUND))

    Tenant.switch(@tenant) do
      places("search_url" => "https://geo.example.test/").find("kensington")

      assert_not Resource::Places.new(key: "x", details: { "search_url" => "ftp://nope" }).valid?
    end

    assert_requested :get, %r{geo\.example\.test/search}
  end

  test "agents are told how to ask it, and asking needs the grant to read the web" do
    stub_request(:get, %r{/search}).to_return(json(FOUND))
    held = places

    Tenant.switch(@tenant) do
      reading = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "a", "scope" => "uris:resources:read uris:web:read"))
      local = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "a", "scope" => "uris:resources:read"))

      assert_match(/do=find, key "#{held.key}"/, Reach.new(reading).told)

      Current.grant = reading
      assert_not Tool::Resources.call(server_context: {}, key: held.key, do: "find", input: { "query" => "x" }).error?

      Current.grant = local
      assert Tool::Resources.call(server_context: {}, key: held.key, do: "find", input: { "query" => "x" }).error?
    ensure
      Current.grant = nil
    end
  end
end
