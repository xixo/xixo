require "net/http"
require "json"

class Resource
  class Search < Resource
    include PublicFetch

    ENDPOINTS = {
      "exa" => "https://api.exa.ai/search",
      "brave" => "https://api.search.brave.com/res/v1/web/search",
      "tavily" => "https://api.tavily.com/search",
      "searxng" => nil
    }.freeze

    KEYLESS = %w[searxng].freeze

    PROVIDERS = ENDPOINTS.keys.freeze
    LIMIT = 8
    MAX_LIMIT = 25
    SNIPPET = 1_000

    serves :search

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "Web search",
        blurb: "Somewhere to look when the answer is not in the catalog. Exa, Brave and " \
               "Tavily each want the same three fields. Results are read and reasoned over; " \
               "nothing found this way is kept.",
        names: "A name for it",
        fields: [
          field("provider", "Provider", required: true, value: "exa",
                help: "exa, brave or tavily."),
          field("endpoint", "Endpoint", help: "Left off, the provider's own."),
          field("api_key", "API key", required: true, secret: true)
        ]
      }
    end

    def self.command_schema
      { search: { query: "string", limit: "integer?" } }
    end

    def self.permitted_origins
      PublicAddress.origins(ENV.fetch("XIXO_SEARCH_ORIGINS", ""))
    end

    def self.named?(target)
      permitted_origins.include?(PublicAddress.origin(target))
    end

    validate :it_names_a_provider_that_answers
    validate :it_is_told_where_a_self_hosted_engine_lives

    def provider
      details.to_h["provider"].to_s.strip.downcase
    end

    def endpoint
      named = details.to_h["endpoint"].presence || ENDPOINTS[provider]
      return named unless provider == "searxng" && named.present?

      URI.parse(named).path.delete_suffix("/").empty? ? "#{named.delete_suffix('/')}/search" : named
    rescue URI::InvalidURIError
      named
    end

    def check!
      look("xixo", 1)
      true
    end

    def search(query, limit: LIMIT)
      wanted = query.to_s.strip
      raise ArgumentError, "#{key}: a search needs something to look for" if wanted.empty?

      look(wanted, limit.to_i.clamp(1, MAX_LIMIT))
    end

    def command_search(query:, limit: nil)
      results = search(query, limit: limit || LIMIT)

      { count: results.size, results: results }
    end

    private

      def look(query, count)
        found(ask(query, count), count)
      end

      def ask(query, count)
        case provider
        when "brave"
          get("#{endpoint}?#{URI.encode_www_form(q: query, count: count)}")
        when "searxng"
          get("#{endpoint}?#{URI.encode_www_form(q: query, format: 'json')}")
        when "tavily"
          post(endpoint, { query: query, max_results: count })
        else
          post(endpoint, { query: query, numResults: count,
                           contents: { text: { maxCharacters: SNIPPET } } })
        end
      end

      def found(body, count)
        rows = provider == "brave" ? body.dig("web", "results") : body["results"]

        Array(rows).first(count).filter_map { |row| result(row) }
      end

      def result(row)
        address = row["url"].presence || row["link"].presence
        return nil if address.blank?

        {
          title: row["title"].to_s.squish.presence,
          url: address,
          snippet: snippet(row),
          published_at: published(row)
        }.compact
      end

      def snippet(row)
        text = row["text"] || row["content"] || row["description"] || row["snippet"]

        text.to_s.squish.truncate(SNIPPET).presence
      end

      def published(row)
        (row["publishedDate"] || row["published_date"] || row["page_age"]).presence
      end

      def get(target)
        answered(over_http(target) { |uri| Net::HTTP::Get.new(uri, headers) })
      end

      def post(target, body)
        answered(
          over_http(target) do |uri|
            request = Net::HTTP::Post.new(uri, headers)
            request.body = JSON.generate(body)
            request
          end
        )
      end

      def answered(response)
        parsed = JSON.parse(response.body.to_s)
        return parsed if parsed.is_a?(Hash)

        raise Resource::Unusable, "#{key}: #{provider} did not answer with an object"
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{provider} did not answer with JSON"
      end

      def headers
        base = { "Accept" => "application/json", "User-Agent" => "xixo" }
        token = credentials.to_h["api_key"].to_s

        case provider
        when "searxng"
          base
        when "brave"
          base.merge("X-Subscription-Token" => token)
        when "tavily"
          base.merge("Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
        else
          base.merge("x-api-key" => token, "Content-Type" => "application/json")
        end
      end

      def it_names_a_provider_that_answers
        unless PROVIDERS.include?(provider)
          errors.add(:details, "must name a provider: #{PROVIDERS.join(', ')}")
        end

        return if KEYLESS.include?(provider)

        errors.add(:credentials, "must carry an api_key") if credentials.to_h["api_key"].blank?
      end

      def it_is_told_where_a_self_hosted_engine_lives
        return unless KEYLESS.include?(provider)
        return if details.to_h["endpoint"].present?

        errors.add(:details, "must name an endpoint — #{provider} is wherever you run it")
      end

      def pinned!(target)
        PublicAddress.pinned!(reached(target), allow_private: self.class.named?(target), through: through)
      rescue PublicAddress::Blocked => e
        raise PublicFetch::Blocked, "#{key}: #{e.message}"
      rescue PublicAddress::Unresolvable => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end
  end
end
