require "test_helper"

class WeatherResourceTest < ActiveSupport::TestCase
  GEOCODED = { results: [
    { name: "Toronto", admin1: "Ontario", country: "Canada", latitude: 43.7, longitude: -79.42 },
    { name: "Toronto", admin1: "Ohio", country: "United States", latitude: 40.46, longitude: -80.6 }
  ] }.freeze

  FORECAST = {
    timezone: "America/Toronto",
    current_units: { temperature_2m: "°C", precipitation: "mm", wind_speed_10m: "km/h" },
    current: { time: "2026-09-27T09:00", interval: 900, temperature_2m: 14.2, weather_code: 61, wind_speed_10m: 12.0 },
    hourly: { time: %w[2026-09-27T09:00 2026-09-27T10:00], temperature_2m: [ 14.2, 15.0 ], weather_code: [ 61, 3 ] },
    daily: { time: %w[2026-09-27 2026-09-28], temperature_2m_max: [ 17.0, 19.5 ], weather_code: [ 63, 0 ] }
  }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "wx-#{SecureRandom.hex(4)}", name: "Weather")
  end

  def weather(credentials: {}, **details)
    Tenant.switch(@tenant) do
      Resource::Weather.create!(key: "weather-#{SecureRandom.hex(3)}", name: "Weather", details: details,
                                credentials: credentials)
    end
  end

  def geocodes(host = "geocoding-api.open-meteo.com")
    stub_request(:get, %r{\Ahttps://#{Regexp.escape(host)}/v1/search})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: GEOCODED.to_json)
  end

  def forecasts(host = "api.open-meteo.com", body: FORECAST, status: 200)
    stub_request(:get, %r{\Ahttps://#{Regexp.escape(host)}/v1/forecast})
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  test "a place is found by name and its weather is said in words, with the units it was measured in" do
    geocodes
    forecasts

    told = Tenant.switch(@tenant) { weather.command("forecast", place: "Toronto") }

    assert_equal "Toronto", told[:place][:name]
    assert_equal "Canada", told[:place][:country]
    assert_equal "America/Toronto", told[:place][:timezone]
    assert_equal [ "Toronto, Ohio, United States" ], told[:place][:others]
    assert_equal "light rain", told[:current]["conditions"]
    assert_nil told[:current]["interval"]
    assert_equal [ "light rain", "overcast" ], told[:hourly].map { |hour| hour["conditions"] }
    assert_equal [ 17.0, 19.5 ], told[:daily].map { |day| day["temperature_2m_max"] }
    assert_equal "°C", told[:units]["temperature_2m"]
    [ /latitude=43\.7/, /longitude=-79\.42/, /forecast_days=3/ ].each { |part| assert_requested :get, part }
  end

  test "coordinates skip the lookup, imperial units are asked for, and the days are bounded" do
    forecasts

    Tenant.switch(@tenant) { weather("units" => "imperial").forecast(latitude: "43.7", longitude: "-79.42", days: 40) }

    [ /temperature_unit=fahrenheit/, /wind_speed_unit=mph/, /precipitation_unit=inch/ ].each { |part| assert_requested :get, part }
    assert_requested :get, /forecast_days=16/
    assert_not_requested :get, %r{geocoding-api}
  end

  test "a key sends the lookups to the paid service, and never shows up in an error" do
    geocodes("customer-geocoding-api.open-meteo.com")
    forecasts("customer-api.open-meteo.com", status: 500, body: { error: true })

    error = assert_raises(Resource::Failed) do
      Tenant.switch(@tenant) { weather(credentials: { "api_key" => "sekrit-key-123" }).forecast(place: "Toronto") }
    end

    assert_requested :get, /customer-geocoding-api.*apikey=sekrit-key-123/
    assert_no_match(/sekrit-key-123/, error.message)
    assert_match(/\[api key\]/, error.message)
  end

  test "a place nobody knows, a forecast of nowhere, and an unknown provider are refused" do
    stub_request(:get, %r{geocoding-api.open-meteo.com}).to_return(status: 200, body: "{}")

    Tenant.switch(@tenant) do
      held = weather

      assert_raises(ArgumentError) { held.forecast(place: "Nowhereville") }
      assert_raises(ArgumentError) { held.forecast }
      assert_not Resource::Weather.new(key: "x", details: { "provider" => "almanac" }).valid?
      assert_not Resource::Weather.new(key: "x", details: { "units" => "kelvin" }).valid?
    end
  end

  test "agents are told how to ask it, and asking needs the grant to read the web" do
    geocodes
    forecasts
    held = weather

    Tenant.switch(@tenant) do
      reading = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "a", "scope" => "xixo:resources:read xixo:web:read"))
      local = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "a", "scope" => "xixo:resources:read"))

      assert_match(/do=forecast, key "#{held.key}"/, Reach.new(reading).told)

      Current.grant = reading
      answered = Tool::Resources.call(server_context: {}, key: held.key, do: "forecast", input: { "place" => "Toronto" })
      assert_not answered.error?, answered.content.first[:text]

      Current.grant = local
      refused = Tool::Resources.call(server_context: {}, key: held.key, do: "forecast", input: { "place" => "Toronto" })
      assert refused.error?
    ensure
      Current.grant = nil
    end
  end
end
