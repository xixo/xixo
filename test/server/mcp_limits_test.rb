require "test_helper"

class McpLimitsTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES
  NONSENSE = { "Authorization" => "Bearer nonsense" }.freeze

  setup do
    Rails.cache.clear

    @tenant = Tenant.create!(subdomain: "limit-#{SecureRandom.hex(4)}", name: "Limited")
    @other = Tenant.create!(subdomain: "limit-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @resource = Resource::S3.create!(key: "limited-bucket", name: "Bucket",
                                       details: { "endpoint" => "http://127.0.0.1:1" })
    end
  end

  def limit
    Rails.configuration.xixo.mcp_limit
  end

  def budget
    Rails.configuration.xixo.run_budget
  end

  def flood(tenant, held, times, session: nil)
    times.times { send_rpc(tenant, held, "tools/list", nil, session: session) }
  end

  def sync
    call(@tenant, ALL, "tools/call", name: "resource",
         arguments: { key: @resource.key, do: "sync" })
  end

  test "a token is bounded at the edge, and the refusal is json-rpc shaped" do
    held, session = session_for(@tenant, ALL)

    flood(@tenant, held, limit - 1, session: session)
    assert_response :success

    send_rpc(@tenant, held, "tools/list", nil, session: session)

    assert_response :too_many_requests
    assert_equal(-32_000, response.parsed_body.dig("error", "code"))
  end

  test "the limiter is reached before the token is verified" do
    flood(@tenant, NONSENSE, limit)
    assert_response :unauthorized

    send_rpc(@tenant, NONSENSE, "tools/list")

    assert_response :too_many_requests
  end

  test "two tokens have two budgets" do
    held, session = session_for(@tenant, ALL)

    flood(@tenant, held, limit, session: session)
    assert_response :too_many_requests

    send_rpc(@tenant, bearer(@tenant, ALL), "initialize",
             { protocolVersion: McpClient::PROTOCOL, capabilities: {},
               clientInfo: { name: "second", version: "1" } })

    assert_response :success
  end

  test "one tenant cannot exhaust another's edge budget" do
    flood(@tenant, NONSENSE, limit + 1)
    assert_response :too_many_requests

    send_rpc(@other, NONSENSE, "tools/list")

    assert_response :unauthorized
  end

  test "starting runs is bounded far tighter than reading is" do
    budget.times do
      reply = sync

      assert_not reply.dig("result", "isError"), reply.dig("result", "content", 0, "text")
    end

    reply = sync

    assert reply.dig("result", "isError")
    assert_match(/#{budget} is the ceiling/, reply.dig("result", "content", 0, "text"))
  end

  test "a tool that starts no run does not spend the run budget" do
    (budget + 5).times do
      call(@tenant, ALL, "tools/call", name: "resource", arguments: { do: "list" })
    end

    reply = sync

    assert_not reply.dig("result", "isError"), reply.dig("result", "content", 0, "text")
  end

  test "being over budget is recorded as denied rather than as an error" do
    (budget + 1).times { sync }

    refused = Tenant.switch(@tenant) { AuditEvent.newest_first.first }

    assert_equal "resource", refused.action
    assert_equal "denied", refused.status
    assert_match(/is the ceiling/, refused.detail)
  end
end
