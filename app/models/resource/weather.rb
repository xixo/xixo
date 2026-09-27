require "net/http"
require "json"

class Resource
  class Weather < Resource
    include PublicFetch

    OPEN_METEO = "open-meteo".freeze
    PROVIDERS = [ OPEN_METEO ].freeze
    UNITS = %w[metric imperial].freeze

    HOSTS = {
      free: { forecast: "https://api.open-meteo.com/v1/forecast",
              geocoding: "https://geocoding-api.open-meteo.com/v1/search" },
      keyed: { forecast: "https://customer-api.open-meteo.com/v1/forecast",
               geocoding: "https://customer-geocoding-api.open-meteo.com/v1/search" }
    }.freeze

    CURRENT = %w[temperature_2m apparent_temperature relative_humidity_2m precipitation weather_code
                 wind_speed_10m wind_direction_10m is_day].freeze
    HOURLY = %w[temperature_2m precipitation_probability precipitation weather_code wind_speed_10m].freeze
    DAILY = %w[weather_code temperature_2m_max temperature_2m_min precipitation_sum
               precipitation_probability_max wind_speed_10m_max sunrise sunset].freeze

    DAYS = 3
    MOST_DAYS = 16
    HOURS = 24
    PLACES = 5

    CONDITIONS = {
      0 => "clear sky", 1 => "mainly clear", 2 => "partly cloudy", 3 => "overcast",
      45 => "fog", 48 => "freezing fog",
      51 => "light drizzle", 53 => "drizzle", 55 => "heavy drizzle",
      56 => "light freezing drizzle", 57 => "freezing drizzle",
      61 => "light rain", 63 => "rain", 65 => "heavy rain",
      66 => "light freezing rain", 67 => "freezing rain",
      71 => "light snow", 73 => "snow", 75 => "heavy snow", 77 => "snow grains",
      80 => "light rain showers", 81 => "rain showers", 82 => "violent rain showers",
      85 => "light snow showers", 86 => "heavy snow showers",
      95 => "thunderstorm", 96 => "thunderstorm with light hail", 99 => "thunderstorm with heavy hail"
    }.freeze

    serves :weather

    def self.attaching
      {
        label: "Weather",
        blurb: "Current conditions and the forecast for any place, looked up when asked. " \
               "Open-Meteo answers without a key for personal use; a key from its paid plan " \
               "is used when one is given. Attach more than one to keep several providers or keys.",
        names: "A name for it",
        fields: [
          field("provider", "Provider", kind: "choice", value: OPEN_METEO,
                options: [ { value: OPEN_METEO, label: "Open-Meteo" } ]),
          field("units", "Units", kind: "choice", value: "metric",
                options: [ { value: "metric", label: "Celsius, km/h, mm" },
                           { value: "imperial", label: "Fahrenheit, mph, inches" } ]),
          field("api_key", "API key", secret: true,
                help: "Left off, the free service answers, which is for non-commercial use.")
        ]
      }
    end

    def self.command_schema
      { forecast: { place: "string?", latitude: "number?", longitude: "number?", days: "integer?" } }
    end

    validate :it_names_a_provider
    validate :its_units_are_known

    def provider
      details.to_h["provider"].presence || OPEN_METEO
    end

    def units
      details.to_h["units"].presence || "metric"
    end

    def check!
      forecast(latitude: 51.5, longitude: -0.13, days: 1)
      true
    end

    def command_forecast(place: nil, latitude: nil, longitude: nil, days: nil)
      forecast(place: place, latitude: latitude, longitude: longitude, days: days)
    end

    def forecast(place: nil, latitude: nil, longitude: nil, days: nil)
      spot = located(place, latitude, longitude)
      wanted = (days.presence || DAYS).to_i.clamp(1, MOST_DAYS)

      answered = get(hosts[:forecast], {
        latitude: spot[:latitude], longitude: spot[:longitude], timezone: "auto",
        current: CURRENT.join(","), hourly: HOURLY.join(","), daily: DAILY.join(","),
        forecast_days: wanted, forecast_hours: HOURS, **unit_params
      })

      {
        place: spot.merge(timezone: answered["timezone"]).compact,
        units: answered["current_units"].to_h.slice("temperature_2m", "precipitation", "wind_speed_10m"),
        current: described(answered["current"].to_h),
        hourly: rows(answered["hourly"].to_h),
        daily: rows(answered["daily"].to_h),
        source: "Weather data by Open-Meteo.com"
      }
    end

    private

      def located(place, latitude, longitude)
        if latitude.present? && longitude.present?
          return { latitude: Float(latitude), longitude: Float(longitude) }
        end

        raise ArgumentError, "#{key}: a forecast needs a place, or a latitude and a longitude" if place.blank?

        found = Array(get(hosts[:geocoding], { name: place.to_s.strip, count: PLACES, format: "json" })["results"])
        best = found.first
        raise ArgumentError, "#{key}: #{provider} knows no place called #{place}" if best.nil?

        {
          name: best["name"], region: best["admin1"], country: best["country"],
          latitude: best["latitude"], longitude: best["longitude"],
          others: found.drop(1).map { |held| [ held["name"], held["admin1"], held["country"] ].compact.join(", ") }.presence
        }.compact
      end

      def rows(series)
        times = Array(series["time"])

        times.each_index.map do |index|
          described(series.transform_values { |values| Array(values)[index] })
        end
      end

      def described(values)
        held = values.except("interval")
        code = held["weather_code"]

        code.nil? ? held : held.merge("conditions" => CONDITIONS[code.to_i]).compact
      end

      def unit_params
        return {} unless units == "imperial"

        { temperature_unit: "fahrenheit", wind_speed_unit: "mph", precipitation_unit: "inch" }
      end

      def hosts
        keyed? ? HOSTS[:keyed] : HOSTS[:free]
      end

      def keyed?
        credentials.to_h["api_key"].present?
      end

      def get(address, params)
        params = params.merge(apikey: credentials.to_h["api_key"]) if keyed?
        response = over_http("#{address}?#{URI.encode_www_form(params)}") do |uri|
          Net::HTTP::Get.new(uri, "Accept" => "application/json", "User-Agent" => "uris")
        end

        parsed = JSON.parse(response.body.to_s)
        raise Resource::Unusable, "#{key}: #{provider} answered #{parsed['reason']}" if parsed.is_a?(Hash) && parsed["error"]
        raise Resource::Unusable, "#{key}: #{provider} did not answer with an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{provider} did not answer with JSON"
      rescue Resource::Failed => e
        raise e.class, redacted(e.message)
      end

      def redacted(message)
        held = credentials.to_h["api_key"].to_s
        held.empty? ? message : message.gsub(held, "[api key]").gsub(CGI.escape(held), "[api key]")
      end

      def it_names_a_provider
        errors.add(:details, "must name a provider: #{PROVIDERS.join(', ')}") unless PROVIDERS.include?(provider)
      end

      def its_units_are_known
        errors.add(:details, "units are #{UNITS.join(' or ')}") unless UNITS.include?(units)
      end
  end
end
