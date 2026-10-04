require "test_helper"

class GraphqlAuthTest < ActionDispatch::IntegrationTest
  CATALOG = "{ feeds { nodes { mime title } } }".freeze
  RESOURCES = "{ resources { key } }".freeze
  ANALYZE = "mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id status } } }".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "auth-#{SecureRandom.hex(4)}", name: "Auth")
    @other = Tenant.create!(subdomain: "auth-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) { @item = create_feed(mime: "application/pdf", title: "An invoice") }

    connect!(@tenant)
  end

  test "a query with no credentials is refused with somewhere to sign in" do
    post "/graphql", params: { query: CATALOG }, headers: host_for(@tenant)

    assert_response :unauthorized

    body = response.parsed_body

    assert_equal false, body["signed_in"]
    assert_equal "login_required", body["error"]
    assert_equal "/auth/", body["login_url"]
    assert_nil response.headers["WWW-Authenticate"],
               "a browser gets a login url; only a caller that presented a token gets a challenge"
  end

  test "an app nobody has connected says so, because there is no login to offer yet" do
    @tenant.update!(client_id: nil, client_secret: nil, connected_at: nil)

    post "/graphql", params: { query: CATALOG }, headers: host_for(@tenant)

    assert_response :unauthorized

    body = response.parsed_body

    assert_equal "handshake_required", body["error"]
    assert_equal "/auth/handshake", body["handshake_url"]
  end

  test "a presented token that is bad gets the bearer challenge, not a login page" do
    post "/graphql", params: { query: CATALOG },
                     headers: host_for(@tenant).merge("Authorization" => "Bearer nonsense")

    assert_response :unauthorized
    assert_match(/\ABearer /, response.headers["WWW-Authenticate"])
    assert_includes response.headers["WWW-Authenticate"], "resource_metadata="
  end

  test "a token minted for another tenant cannot read this one" do
    post "/graphql", params: { query: CATALOG },
                     headers: host_for(@tenant).merge(bearer(@other))

    assert_response :unauthorized
  end

  test "a granted token reads the catalog" do
    post "/graphql", params: { query: CATALOG },
                     headers: host_for(@tenant).merge(bearer(@tenant))

    assert_response :success
    assert_equal [ { "mime" => "application/pdf", "title" => "An invoice" } ],
                 response.parsed_body.dig("data", "feeds", "nodes")
  end

  test "a read scope does not carry the resource list" do
    body = execute(RESOURCES, scopes: %w[xixo:catalog:read])

    assert_nil body.dig("data", "resources")
    assert_match(/does not carry xixo:resources:read/, body.dig("errors", 0, "message"))
  end

  test "a read scope cannot drive a mutation" do
    body = execute(ANALYZE, scopes: %w[xixo:catalog:read], variables: { id: @item.id.to_s })

    assert_match(/does not carry xixo:catalog:write/, body.dig("errors", 0, "message"))
  end

  test "a write scope can" do
    body = execute(ANALYZE, scopes: %w[xixo:catalog:read xixo:catalog:write],
                            variables: { id: @item.id.to_s })

    assert_nil body["errors"]
    assert body.dig("data", "analyzeFeed", "analysis", "id").present?
  end

  test "resource commands want the resource scope, not the write scope" do
    body = execute(RESOURCES, scopes: %w[xixo:catalog:write xixo:resources:read])

    assert_nil body["errors"]
  end

  test "a read scope cannot walk from an item to a resource" do
    query = "{ feeds { nodes { references { resource { key } } } } }"

    body = execute(query, scopes: %w[xixo:catalog:read])

    assert_nil body.dig("data", "feeds"),
               "nesting must not reach past the scope the entry point checked"
    assert body["errors"].present?
  end

  test "holding both scopes walks the whole way" do
    query = "{ feeds { nodes { references { resource { key } } } } }"

    body = execute(query, scopes: %w[xixo:catalog:read xixo:resources:read])

    assert_nil body["errors"]
    assert body.dig("data", "feeds", "nodes", 0, "references", 0, "resource", "key").present?
  end

  test "streaming a reference out needs a grant too" do
    reference = Tenant.switch(@tenant) { @item.references.first }

    get "/references/#{reference.id}/content", headers: host_for(@tenant)

    assert_response :unauthorized
  end


  test "a bearer caller is not refused as forgery before it is authenticated" do
    ActionController::Base.allow_forgery_protection = true

    post "/graphql", params: { query: CATALOG },
                     headers: host_for(@tenant).merge(bearer(@tenant, scopes: [ "xixo:catalog:read" ]))

    assert_response :success
    assert_equal [ { "mime" => "application/pdf", "title" => "An invoice" } ],
                 response.parsed_body.dig("data", "feeds", "nodes")
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "a browser without a csrf token is still refused as forgery" do
    ActionController::Base.allow_forgery_protection = true

    post "/graphql", params: { query: CATALOG }, headers: host_for(@tenant)

    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  private

    def host_for(tenant)
      { "HOST" => "#{tenant.subdomain}.xixo.test" }
    end

    def bearer(tenant, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes,
        audience: "http://#{tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end

    def execute(query, scopes:, variables: nil)
      post "/graphql",
           params: { query: query, variables: variables }.compact,
           headers: host_for(@tenant).merge(bearer(@tenant, scopes: scopes))

      response.parsed_body
    end
end
