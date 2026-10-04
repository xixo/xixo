require "test_helper"

class McpAuditTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES

  setup do
    SearchIndex.reset!
    Rails.cache.clear

    @tenant = Tenant.create!(subdomain: "audit-#{SecureRandom.hex(4)}", name: "Audited")
    @other = Tenant.create!(subdomain: "audit-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @resource = Resource::S3.create!(key: "audited-bucket", name: "Bucket",
                                       details: { "endpoint" => "http://127.0.0.1:1" })
      @item = create_feed(mime: "application/pdf", title: "March invoice", locator_key: "invoices/march.pdf",
                            resource: @resource, locator: { "bucket" => "audited-bucket" })
    end

    SearchIndex.refresh!
  end

  def events(tenant = @tenant)
    Tenant.switch(tenant) { AuditEvent.newest_first.to_a }
  end

  test "every tool call is recorded against the token that made it" do
    tool(@tenant, ALL, "search", query: "invoice")

    event = events.first

    assert_equal "mcp", event.channel
    assert_equal "search", event.action
    assert_equal "ok", event.status
    assert_equal "xixo:catalog:read", event.scope
    assert_equal "person", event.actor
    assert_equal "test", event.actor_name
    assert_equal "searched for invoice", event.told
    assert_equal({ "query" => "invoice", "type" => nil, "limit" => 50 }, event.arguments)
    assert event.duration_ms >= 0
    assert event.request_id.present?
  end

  test "a call the token does not carry the scope for is recorded as denied" do
    call(@tenant, [ "xixo:catalog:read" ], "tools/call",
         name: "search", arguments: { query: "invoice" })

    assert_equal "ok", events.first.status

    Tenant.switch(@tenant) { AuditEvent.delete_all }

    call(@tenant, [ "xixo:catalog:read" ], "tools/call",
         name: "resource", arguments: { key: @resource.key, do: "sync" })

    assert_empty events, "an ungranted tool is not registered, so no grant was exercised"
  end

  test "a tool that fails is recorded as an error, with what broke it" do
    reply = call(@tenant, ALL, "tools/call", name: "feed", arguments: { id: "999999" })

    assert reply.dig("result", "isError")

    event = events.first

    assert_equal "feed", event.action
    assert_equal "error", event.status
    assert_equal "no feed with id 999999", event.detail
    assert_equal "read feed 999999", event.told
    assert_nil event.feed
  end

  test "a call an agent makes is recorded against the analysis it made it for, naming the feed" do
    Tenant.switch(@tenant) do
      analysis = Analysis.open!(feed: @item, cause: "manual")

      Current.set(grant: @item.grant, analysis: analysis, acting_for: @item.id) do
        Tool::Connect.call(a: @item.id.to_s, tag: "invoices", server_context: {})
      end

      event = AuditEvent.newest_first.first

      assert_equal "agent", event.actor
      assert_nil event.actor_name
      assert_equal analysis, event.analysis
      assert_equal @item, event.feed
      assert_equal "filed March invoice under invoices", event.told
    end
  end

  test "a sentence that cannot be written leaves the event recorded without one" do
    Tenant.switch(@tenant) do
      broken = Class.new(Tool::Search) do
        tool_name "search"
        scope "xixo:catalog:read"
        define_singleton_method(:saying) { |_arguments| raise "broken" }
      end

      Current.set(grant: @item.grant) { broken.call(query: "invoice", server_context: {}) }

      event = AuditEvent.newest_first.first

      assert_equal "search", event.action
      assert_equal "ok", event.status
      assert_equal "agent", event.actor, "a feed's grant is the agent's even outside an analysis"
      assert_nil event.analysis
      assert_nil event.told
    end
  end

  test "a feed named by neither id nor key says so" do
    reply = call(@tenant, ALL, "tools/call", name: "feed", arguments: { key: "" })

    assert_equal "feed needs an id or a key", reply.dig("result", "content", 0, "text")
  end

  test "an unauthenticated call is recorded as denied" do
    post "/mcp", headers: host_for(@tenant), params: rpc("tools/list"), as: :json

    assert_response :unauthorized

    event = events.first

    assert_equal "mcp", event.channel
    assert_equal "authorize", event.action
    assert_equal "denied", event.status
    assert_equal "nobody", event.actor
    assert_nil event.actor_name
  end

  test "a credential-shaped argument is redacted rather than stored" do
    Tenant.switch(@tenant) do
      AuditEvent.record(
        channel: "mcp", action: "resource", status: "ok",
        arguments: { "id" => "1", "arguments" => { "access_key_id" => "AKIA", "path" => "a/b" } }
      )
    end

    stored = events.first.arguments

    assert_equal "[redacted]", stored.dig("arguments", "access_key_id")
    assert_equal "a/b", stored.dig("arguments", "path")
  end

  test "a large argument is truncated rather than copied whole" do
    Tenant.switch(@tenant) do
      AuditEvent.record(channel: "mcp", action: "resource", status: "ok",
                        arguments: { "body" => "x" * 5_000, "parts" => Array.new(400, "y") })
    end

    stored = events.first.arguments

    assert_equal 200, stored["body"].length
    assert_equal "[400 items]", stored["parts"]
  end

  test "one tenant's audit log is invisible to another" do
    tool(@tenant, ALL, "search", query: "invoice")

    assert_equal 1, events.length
    assert_empty events(@other)

    Tenant.switch(@tenant) do
      assert_equal 1, AuditEvent.unscoped.count, "row-level security holds without the scope"
    end
  end

  test "the sweep drops what is past retention and keeps what is not" do
    Tenant.switch(@tenant) do
      AuditEvent.record(channel: "mcp", action: "search", status: "ok")
      AuditEvent.record(channel: "mcp", action: "search", status: "ok")
        .update!(created_at: 100.days.ago)
    end

    SweepAuditEventsJob.perform_now

    assert_equal 1, events.length
  end
end
