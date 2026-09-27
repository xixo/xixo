require "net/http"
require "json"

class Resource
  class Places < Resource
    include PublicFetch

    OPENSTREETMAP = "openstreetmap".freeze
    PROVIDERS = [ OPENSTREETMAP ].freeze
    SEARCH = "https://nominatim.openstreetmap.org".freeze
    NEARBY = "https://overpass-api.de/api/interpreter".freeze
    AGENT = "uris (https://github.com/urisrb/uris)".freeze

    FOUND = 5
    MOST_FOUND = 20
    RADIUS = 800
    RADII = (50..5_000)
    NEAR = 20
    KIND = /\A[a-z][a-z_]{0,40}\z/
    GROUPS = %w[amenity shop tourism leisure healthcare office craft].freeze
    SPACING = 1.1
    OVERPASS_SECONDS = 25

    serves :places

    class << self
      def attaching
        {
          label: "Places",
          blurb: "Addresses, coordinates, and what is nearby, from OpenStreetMap. It answers without a key: " \
                 "Nominatim finds a place and names coordinates, and Overpass finds what is around them. The " \
                 "public servers ask for a light touch, so point it at your own for heavy use.",
          names: "A name for it",
          fields: [
            field("provider", "Provider", kind: "choice", value: OPENSTREETMAP,
                  options: [ { value: OPENSTREETMAP, label: "OpenStreetMap" } ]),
            field("search_url", "Search server", placeholder: SEARCH,
                  help: "A Nominatim server. Left off, the public one, which allows about one request a second."),
            field("nearby_url", "Nearby server", placeholder: NEARBY,
                  help: "An Overpass API interpreter. Left off, the public one."),
            field("photos", "Name where photos were taken", kind: "boolean", value: "false",
                  help: "Sends the coordinates in each photo's EXIF to the search server, so a photo is " \
                        "catalogued by the place it was taken.")
          ]
        }
      end

      def command_schema
        {
          find: { query: "string", limit: "integer?" },
          reverse: { latitude: "number", longitude: "number" },
          nearby: { kind: "string", place: "string?", latitude: "number?", longitude: "number?", radius: "integer?" }
        }
      end

      attr_writer :spacing

      def spacing
        @spacing || SPACING
      end

      def turn
        @turn ||= Mutex.new
      end

      def last_asked
        @last_asked ||= {}
      end
    end

    validate :it_names_a_provider
    validate :its_servers_are_addresses

    def provider
      details.to_h["provider"].presence || OPENSTREETMAP
    end

    def search_url
      details.to_h["search_url"].presence&.chomp("/") || SEARCH
    end

    def nearby_url
      details.to_h["nearby_url"].presence || NEARBY
    end

    def names_photos?
      ActiveModel::Type::Boolean.new.cast(details.to_h["photos"]) == true
    end

    def check!
      find("Toronto", limit: 1)
      true
    end

    def command_find(query:, limit: nil)
      { found: find(query, limit: limit) }
    end

    def command_reverse(latitude:, longitude:)
      reverse(latitude, longitude)
    end

    def command_nearby(kind:, place: nil, latitude: nil, longitude: nil, radius: nil)
      nearby(kind, place: place, latitude: latitude, longitude: longitude, radius: radius)
    end

    def find(query, limit: nil)
      wanted = query.to_s.squish
      raise ArgumentError, "#{key}: find needs a place or an address to look for" if wanted.empty?

      rows = asked("#{search_url}/search", q: wanted, format: "jsonv2", addressdetails: 1,
                                          limit: (limit.presence || FOUND).to_i.clamp(1, MOST_FOUND))

      Array(rows).filter_map { |row| described(row) if row.is_a?(Hash) }
    end

    def reverse(latitude, longitude)
      lat, lon = coordinates!(latitude, longitude)
      row = asked("#{search_url}/reverse", lat: lat, lon: lon, format: "jsonv2", addressdetails: 1, zoom: 18)

      raise ArgumentError, "#{key}: nothing is known at #{lat}, #{lon}" unless row.is_a?(Hash) && row["display_name"]

      described(row)
    end

    def nearby(kind, place: nil, latitude: nil, longitude: nil, radius: nil)
      wanted = kind.to_s.strip.downcase.tr(" ", "_")
      raise ArgumentError, "#{key}: kind is a word such as cafe, pharmacy or park" unless wanted.match?(KIND)

      centre = centred(place, latitude, longitude)
      around = (radius.presence || RADIUS).to_i.clamp(RADII.min, RADII.max)
      groups = GROUPS.join("|")
      query = "[out:json][timeout:#{OVERPASS_SECONDS}];" \
              "nwr(around:#{around},#{centre[:latitude]},#{centre[:longitude]})" \
              "[~\"^(#{groups})$\"~\"^#{wanted}$\"];out center #{NEAR};"

      answered = posted(nearby_url, data: query)

      {
        around: centre.merge(radius: around),
        kind: wanted,
        found: Array(answered["elements"]).filter_map { |element| spot(element, centre) }.sort_by { |held| held[:metres] }
      }
    end

    private

      def described(row)
        address = row["address"].to_h

        {
          name: row["name"].presence,
          address: row["display_name"],
          kind: [ row["category"], row["type"] ].compact.join("/").presence,
          latitude: row["lat"]&.to_f,
          longitude: row["lon"]&.to_f,
          neighbourhood: address["neighbourhood"] || address["suburb"] || address["quarter"],
          city: address["city"] || address["town"] || address["village"] || address["municipality"],
          region: address["state"] || address["province"],
          country: address["country"],
          postcode: address["postcode"]
        }.compact
      end

      def spot(element, centre)
        lat = element["lat"] || element.dig("center", "lat")
        lon = element["lon"] || element.dig("center", "lon")
        return nil if lat.nil? || lon.nil?

        tags = element["tags"].to_h
        street = [ tags["addr:housenumber"], tags["addr:street"] ].compact.join(" ").presence

        {
          name: tags["name"],
          kind: GROUPS.filter_map { |group| tags[group] }.first,
          address: street,
          opening_hours: tags["opening_hours"],
          website: tags["website"] || tags["contact:website"],
          latitude: lat.to_f,
          longitude: lon.to_f,
          metres: distance(centre[:latitude], centre[:longitude], lat.to_f, lon.to_f).round
        }.compact
      end

      def centred(place, latitude, longitude)
        return %i[latitude longitude].zip(coordinates!(latitude, longitude)).to_h if latitude.present? && longitude.present?

        raise ArgumentError, "#{key}: nearby needs a place, or a latitude and a longitude" if place.blank?

        best = find(place, limit: 1).first || raise(ArgumentError, "#{key}: no place called #{place} was found")
        { name: best[:address], latitude: best[:latitude], longitude: best[:longitude] }
      end

      def coordinates!(latitude, longitude)
        lat = Float(latitude.to_s, exception: false)
        lon = Float(longitude.to_s, exception: false)

        unless lat&.between?(-90, 90) && lon&.between?(-180, 180)
          raise ArgumentError, "#{key}: #{latitude}, #{longitude} are not coordinates"
        end

        [ lat.round(6), lon.round(6) ]
      end

      def distance(lat1, lon1, lat2, lon2)
        rad = Math::PI / 180
        a = (Math.sin((lat2 - lat1) * rad / 2)**2) +
            (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin((lon2 - lon1) * rad / 2)**2))

        6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
      end

      def asked(address, params)
        spaced(address)
        parsed(over_http("#{address}?#{URI.encode_www_form(params)}") { |uri| Net::HTTP::Get.new(uri, headers) })
      end

      def posted(address, form)
        spaced(address)
        parsed(
          over_http(address) do |uri|
            Net::HTTP::Post.new(uri, headers).tap { |request| request.set_form_data(form) }
          end
        )
      end

      def spaced(address)
        host = URI.parse(address).host

        self.class.turn.synchronize do
          waited = self.class.last_asked[host]
          pause = waited ? self.class.spacing - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - waited) : 0
          sleep(pause) if pause.positive?
          self.class.last_asked[host] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def headers
        { "Accept" => "application/json", "User-Agent" => AGENT }
      end

      def parsed(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{provider} did not answer with JSON"
      end

      def it_names_a_provider
        errors.add(:details, "must name a provider: #{PROVIDERS.join(', ')}") unless PROVIDERS.include?(provider)
      end

      def its_servers_are_addresses
        [ search_url, nearby_url ].each do |address|
          uri = URI.parse(address)
          errors.add(:details, "#{address} is not an http or https address") unless uri.is_a?(URI::HTTP) && uri.host.present?
        rescue URI::InvalidURIError
          errors.add(:details, "#{address} is not an address")
        end
      end
  end
end
