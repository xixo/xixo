require "test_helper"
require_relative "../support/machines"

class LinkUpdatesPageTest < ActionDispatch::IntegrationTest
  include Machines

  SHIPPED = Resource::Machine::Downloads.version
  OLD = Digest::SHA256.hexdigest("old binary")
  UPDATES = "{ linkUpdates { release protocol rollout { phase version firstMachines { os resource { key } } } machines { key machine { updateState protocol } } } }".freeze
  REQUEST = <<~GQL.freeze
    mutation($id: ID, $action: String!) {
      requestMachineUpdate(input: { id: $id, action: $action }) { linkUpdates { rollout { phase firstMachines { os resource { key } picked } } } }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "linkup-#{SecureRandom.hex(4)}", name: "Link updates")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-arm64"), "linux binary")
    listed = [ { "name" => "xixo-link-linux-arm64", "sha256" => Digest::SHA256.hexdigest("linux binary") } ]
    File.write(File.join(@binaries, "release.json"), { "version" => SHIPPED, "serial" => 1234, "protocol" => 1, "files" => listed }.to_json)
    File.write(File.join(@binaries, "release.sigstore.json"), "{}")
    ENV["XIXO_LINK_DIR"] = @binaries
    @machine = machine_on(@tenant, key: "box")
    Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge(
        "os" => "linux", "arch" => "arm64", "version" => "0.0.1", "sha256" => OLD, "updates" => "systemd", "protocol" => 1,
        "releases" => [ { "release" => Digest::SHA256.hexdigest("r0"), "sha256" => Digest::SHA256.hexdigest("before"), "version" => "0.0.0", "serial" => 3, "protocol" => 1 } ]
      )))
    end
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    FileUtils.rm_rf(@binaries)
  end

  test "an administrator sees the rollout and where each machine stands, and a member sees nothing" do
    held = graphql(Grant::SCOPES, UPDATES).dig("data", "linkUpdates")

    assert_equal [ SHIPPED, 1, "waiting_for_server", SHIPPED ], [ held["release"], held["protocol"], held.dig("rollout", "phase"), held.dig("rollout", "version") ]
    assert_equal [ { "key" => "box", "machine" => { "updateState" => "waiting", "protocol" => 1 } } ], held["machines"]

    assert_nil graphql(Grant::SIGN_IN, UPDATES).dig("data", "linkUpdates")
  end

  test "an administrator updates a machine now, picks it to go first, rolls it back, and pauses the rollout" do
    stream = LinkChannel.broadcasting_for(@machine)

    graphql(Grant::SCOPES, REQUEST, id: @machine.id, action: "update_now")
    assert_equal [ SHIPPED ], heard(stream, "update").map { |held| held["version"] }

    held = graphql(Grant::SCOPES, REQUEST, id: @machine.id, action: "first").dig("data", "requestMachineUpdate", "linkUpdates", "rollout")
    assert_equal [ "first", [ { "os" => "linux", "resource" => { "key" => "box" }, "picked" => true } ] ], held.values_at("phase", "firstMachines")

    graphql(Grant::SCOPES, REQUEST, id: @machine.id, action: "roll_back")
    assert_equal [ "0.0.0" ], heard(stream, "roll_back").map { |held| held["version"] }

    held = graphql(Grant::SCOPES, REQUEST, action: "pause").dig("data", "requestMachineUpdate", "linkUpdates", "rollout")
    assert_equal "paused", held["phase"]

    Tenant.switch(@tenant) do
      assert_equal %w[update_now first roll_back pause], AuditEvent.where(action: "request_machine_update").order(:id).map { |event| event.arguments["action"] }
    end

    assert_match(/not something/, graphql(Grant::SCOPES, REQUEST, id: @machine.id, action: "reboot").dig("errors", 0, "message"))
    assert_match(/administrator/, graphql(Grant::SIGN_IN, REQUEST, action: "pause").dig("errors", 0, "message"))
  end

  private

    def heard(stream, kind)
      ActionCable.server.pubsub.broadcasts(stream).filter_map { |held| JSON.parse(held)[kind] }
    end

    def graphql(scopes, query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }

      response.parsed_body
    end
end
