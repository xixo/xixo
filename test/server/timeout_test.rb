require "test_helper"

class TimeoutTest < ActionDispatch::IntegrationTest
  SET = <<~GQL.freeze
    mutation($id: ID!, $seconds: Int) {
      setFeedTimeout(input: { id: $id, seconds: $seconds }) { feed { id timeout timeAllowed } }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "time-#{SecureRandom.hex(4)}", name: "Timeouts")

    Tenant.switch(@tenant) { @feed = Feed.create!(type: Feed::NOTE, key: "slow", title: "slow") }

    connect!(@tenant)
  end

  test "a feed nobody has set runs for ten minutes, and one set runs for as long as it was given" do
    fresh = execute(SET, variables: { id: @feed.id })

    assert_nil fresh.dig("data", "setFeedTimeout", "feed", "timeout")
    assert_equal 600, fresh.dig("data", "setFeedTimeout", "feed", "timeAllowed")

    set = execute(SET, variables: { id: @feed.id, seconds: 3600 })

    assert_equal 3600, set.dig("data", "setFeedTimeout", "feed", "timeAllowed")
  end

  test "a timeout past a day or under a minute is refused" do
    [ 86_401, 59 ].each do |seconds|
      body = execute(SET, variables: { id: @feed.id, seconds: seconds })

      assert_nil body.dig("data", "setFeedTimeout")
      assert_match(/Timeout/, body.dig("errors", 0, "message"))
    end

    Tenant.switch(@tenant) { assert_nil @feed.reload.timeout }
  end

  test "setting a timeout needs the write scope" do
    body = execute(SET, variables: { id: @feed.id, seconds: 3600 }, scopes: %w[xixo:catalog:read])

    assert_nil body.dig("data", "setFeedTimeout")
    Tenant.switch(@tenant) { assert_nil @feed.reload.timeout }
  end

  private

    def execute(query, variables: nil, scopes: Grant::SCOPES)
      token = issuer.mint(subdomain: @tenant.subdomain, scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
