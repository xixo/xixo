require "test_helper"
require "masks/client/delegations/fake"

class ConnectingTest < ActionDispatch::IntegrationTest
  RESOURCES = <<~GQL.freeze
    { resources { id key delegated needsConnect connectedBy connectUrl } }
  GQL

  setup do
    @masks = Delegations.fake = Masks::Client::Delegations::Fake.new
    @tenant = Tenant.create!(subdomain: "connect-#{SecureRandom.hex(4)}", name: "Connecting")

    connect!(@tenant)

    @resource = Tenant.switch(@tenant) { Resource::MicrosoftGraph.create!(key: "onedrive") }
  end

  teardown do
    Delegations.fake = nil
  end

  def headers(subject: "ada", scopes: Grant::SCOPES)
    token = issuer.mint(subdomain: @tenant.subdomain, subject: subject, scopes: scopes,
                        audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

    { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }
  end

  def start(**options)
    get "/resources/#{@resource.id}/connect", params: options.slice(:prompt), headers: headers(**options.except(:prompt))

    location = URI.parse(response.location)
    Rack::Utils.parse_query(location.query)
  end

  def come_back(params, **options)
    get "/connect/callback", params: params, headers: headers(**options)
  end

  def landed_error
    Rack::Utils.parse_query(URI.parse(response.location).query)["connect_error"]
  end

  test "connecting goes through masks and comes back holding the delegation" do
    started = start

    assert_response :redirect
    assert_equal "microsoft", started["provider"]

    stub_request(:get, "https://graph.microsoft.com/v1.0/me").to_return(status: 200, body: { id: "u1" }.to_json)
    stub_request(:get, "https://graph.microsoft.com/v1.0/me/drive").to_return(status: 200, body: { id: "d1" }.to_json)

    come_back(@masks.approve(started, subject: "ada", connection: "c-9"))

    assert_redirected_to "/settings/resources/#{@resource.id}"
    assert_nil landed_error

    Tenant.switch(@tenant) do
      held = @resource.reload

      assert held.connected?
      refute held.needs_connect?
      assert_equal "ada", held.connected_by
      assert_equal "c-9", held.delegation["connection"]
      assert held.healthy?, held.check_error
    end

    listed = post_graphql(RESOURCES).dig("data", "resources").find { |one| one["key"] == "onedrive" }

    assert_equal false, listed["needsConnect"]
    assert_equal "ada", listed["connectedBy"]
    assert_equal "/resources/#{@resource.id}/connect", listed["connectUrl"]
  end

  test "a state that does not match what this browser started is refused" do
    started = start

    come_back(@masks.approve(started).merge("state" => "forged"))

    assert_match(/state/, landed_error)
    Tenant.switch(@tenant) { refute @resource.reload.connected? }
  end

  test "a callback nobody started in this browser connects nothing" do
    come_back(@masks.approve({ "state" => "s", "provider" => "microsoft" }))

    assert_match(/expired|another browser/, landed_error)
    Tenant.switch(@tenant) { refute @resource.reload.connected? }
  end

  test "somebody else finishing what another person started connects nothing" do
    started = start(subject: "ada")

    come_back(@masks.approve(started, subject: "mallory"), subject: "mallory")

    assert_match(/expired|another browser/, landed_error)
    Tenant.switch(@tenant) { refute @resource.reload.connected? }
  end

  test "masks connecting a different person than the one who started is refused" do
    started = start(subject: "ada")

    come_back(@masks.approve(started, subject: "mallory"))

    assert_match(/somebody other/, landed_error)
    Tenant.switch(@tenant) { refute @resource.reload.connected? }
  end

  test "a person who declines at masks is told so, and nothing is connected" do
    started = start

    come_back(@masks.deny(started))

    assert_equal "the person declined", landed_error
  end

  test "masks asking for a fresh sign-in sends the browser round once more with prompt=login" do
    started = start

    come_back(@masks.deny(started, error: "login_required", description: "sign in again"))

    assert_response :redirect
    assert_equal "login", Rack::Utils.parse_query(URI.parse(response.location).query)["prompt"]

    come_back(@masks.deny(Rack::Utils.parse_query(URI.parse(response.location).query), error: "login_required", description: "sign in again"))

    assert_equal "sign in again", landed_error
  end

  test "connecting needs the command scope" do
    get "/resources/#{@resource.id}/connect", headers: headers(scopes: %w[xixo:resources:read])

    refute_predicate response, :redirect?
    Tenant.switch(@tenant) { refute @resource.reload.connected? }
  end

  test "a resource that does not connect through masks has nothing to connect" do
    other = Tenant.switch(@tenant) { Resource::Rss.create!(key: "news", details: { "url" => "https://news.example.com/feed.xml" }) }

    get "/resources/#{other.id}/connect", headers: headers

    assert_response :not_found
  end

  private

    def post_graphql(query)
      post "/graphql", params: { query: query }, headers: headers

      response.parsed_body
    end
end
