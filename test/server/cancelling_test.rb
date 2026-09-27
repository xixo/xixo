require "test_helper"

class CancellingTest < ActionDispatch::IntegrationTest
  CANCEL = <<~GQL.freeze
    mutation($id: ID!) {
      cancelAnalysis(input: { id: $id }) { cancelled analysis { id status } }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "stop-#{SecureRandom.hex(4)}", name: "Cancelling")

    Tenant.switch(@tenant) do
      @feed = Feed.create!(type: Feed::NOTE, key: "a question", title: "A question")
      @analysis = @feed.analyses.create!(cause: "ask", status: "running", started_at: Time.current)
    end

    connect!(@tenant)
  end

  test "an analysis under way is cancelled and reports as cancelled" do
    body = execute(CANCEL, variables: { id: @analysis.id })

    assert_equal true, body.dig("data", "cancelAnalysis", "cancelled")
    assert_equal "cancelled", body.dig("data", "cancelAnalysis", "analysis", "status")
    Tenant.switch(@tenant) do
      assert_equal "cancelled", @analysis.reload.status
      assert @analysis.finished_at
    end
  end

  test "one already finished is left as it was" do
    Tenant.switch(@tenant) { @analysis.update_columns(status: "done") }

    body = execute(CANCEL, variables: { id: @analysis.id })

    assert_equal false, body.dig("data", "cancelAnalysis", "cancelled")
    assert_equal "done", body.dig("data", "cancelAnalysis", "analysis", "status")
  end

  test "an analysis that does not exist is refused" do
    body = execute(CANCEL, variables: { id: 0 })

    assert_match(/no analysis with id 0/, body.dig("errors", 0, "message"))
  end

  test "cancelling needs the write scope, not the read one" do
    body = execute(CANCEL, scopes: %w[uris:catalog:read], variables: { id: @analysis.id })

    assert_nil body.dig("data", "cancelAnalysis")
    Tenant.switch(@tenant) { assert_equal "running", @analysis.reload.status }
  end

  private

    def host_for(tenant)
      { "HOST" => "#{tenant.subdomain}.uris.test" }
    end

    def bearer(tenant, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes,
        audience: "http://#{tenant.subdomain}.uris.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end

    def execute(query, variables: nil, scopes: Grant::SCOPES)
      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: host_for(@tenant).merge(bearer(@tenant, scopes: scopes))

      response.parsed_body
    end
end
