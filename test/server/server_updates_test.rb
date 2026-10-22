require "test_helper"

class ServerUpdatesTest < ActionDispatch::IntegrationTest
  UPDATES = "{ serverUpdates { manual channel paused images { name current revision target containers { name stale } } events { action kind by } } }".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "updates-#{SecureRandom.hex(4)}", name: "Updates")
    connect!(@tenant)

    @dir = Dir.mktmpdir
    @held = ENV.to_h.slice("XIXO_UPDATES_TENANT", "XIXO_UPDATES_STATE", "XIXO_UPDATES_REQUEST")
    ENV["XIXO_UPDATES_TENANT"] = @tenant.subdomain
    ENV["XIXO_UPDATES_STATE"] = @dir
    ENV["XIXO_UPDATES_REQUEST"] = File.join(@dir, "request.json")
  end

  teardown do
    %w[XIXO_UPDATES_TENANT XIXO_UPDATES_STATE XIXO_UPDATES_REQUEST].each { |name| ENV[name] = @held[name] }
    FileUtils.rm_rf(@dir)
  end

  test "an administrator sees which build each image runs, what is newer, and what the updater did" do
    report!
    File.write(File.join(@dir, "events.jsonl"), [
      { at: "2026-10-22T02:21:53Z", action: "pull", kind: "xixo", digest: "sha256:new" },
      { at: "2026-10-22T02:22:00Z", action: "pause", by: "bob" },
      "not json"
    ].map { |held| held.is_a?(String) ? held : held.to_json }.join("\n"))

    updates = graphql(Grant::SCOPES, UPDATES).dig("data", "serverUpdates")

    assert_equal false, updates["manual"]
    assert_equal "main", updates["channel"]
    assert_equal [ "xixo", "sha256:old", "c589ffe", "sha256:new" ], updates["images"][0].values_at("name", "current", "revision", "target")
    assert_equal [ { "name" => "xixo-xixo-1", "stale" => false } ], updates["images"][0]["containers"]
    assert_equal [ "pause", "pull" ], updates["events"].map { |held| held["action"] }
  end

  test "a server with no updater says its updates are manual" do
    updates = graphql(Grant::SCOPES, UPDATES).dig("data", "serverUpdates")

    assert_equal true, updates["manual"]
    assert_empty updates["images"]
  end

  test "a member, or an administrator of another tenant, sees nothing" do
    report!

    assert_nil graphql(Grant::SIGN_IN, UPDATES).dig("data", "serverUpdates")

    ENV["XIXO_UPDATES_TENANT"] = "someone-else"
    assert_nil graphql(Grant::SCOPES, UPDATES).dig("data", "serverUpdates")
  end

  test "an administrator's request is written for the updater, and audited" do
    body = graphql(Grant::SCOPES, %(mutation { requestServerUpdate(input: { action: "channel", channel: "releases" }) { serverUpdates { manual } } }))

    assert_nil body["errors"]
    asked = JSON.parse(File.read(File.join(@dir, "request.json")))
    assert_equal({ "action" => "channel", "channel" => "releases", "by" => "bob" }, asked.except("at"))
    assert_in_delta Time.current, Time.iso8601(asked["at"]), 5

    Tenant.switch(@tenant) do
      assert AuditEvent.exists?(action: "request_server_update", status: "ok")
    end
  end

  test "a request the updater does not take, or from someone who may not ask, is refused and not written" do
    [
      [ Grant::SIGN_IN, %(mutation { requestServerUpdate(input: { action: "pause" }) { serverUpdates { manual } } }), /administrator/ ],
      [ Grant::SCOPES, %(mutation { requestServerUpdate(input: { action: "delete" }) { serverUpdates { manual } } }), /not something/ ],
      [ Grant::SCOPES, %(mutation { requestServerUpdate(input: { action: "channel", channel: "nightly" }) { serverUpdates { manual } } }), /main or releases/ ]
    ].each do |scopes, mutation, message|
      assert_match message, graphql(scopes, mutation).dig("errors", 0, "message").to_s, mutation
    end

    ENV["XIXO_UPDATES_TENANT"] = "someone-else"
    assert_match(/operator/, graphql(Grant::SCOPES, %(mutation { requestServerUpdate(input: { action: "pause" }) { serverUpdates { manual } } })).dig("errors", 0, "message"))

    assert_not File.exist?(File.join(@dir, "request.json"))
  end

  private

    def report!
      File.write(File.join(@dir, "status.json"), {
        channel: "main", paused: false, checked_at: "2026-10-22T02:21:53Z",
        kinds: [ { name: "xixo", current: "sha256:old", revision: "c589ffe", containers: [ { name: "xixo-xixo-1", state: "running" } ] } ],
        targets: { xixo: "sha256:new" }
      }.to_json)
    end

    def graphql(scopes, query)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query }, headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
