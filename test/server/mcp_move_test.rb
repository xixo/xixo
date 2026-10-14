require "test_helper"
require_relative "../support/machines"

class McpMoveTest < ActionDispatch::IntegrationTest
  include McpClient
  include Machines
  include ActiveJob::TestHelper

  COMMAND = %w[xixo:resources:read xixo:resources:command].freeze

  setup do
    @tenant = Tenant.create!(subdomain: "move-mcp-#{SecureRandom.hex(4)}", name: "Moving")
    @mac = writing(machine_on(@tenant, key: "mac", folders: [ "/Users/jon/Pictures" ], operators: [ "test" ]), "/Users/jon/Pictures")
    @media = writing(machine_on(@tenant, key: "media", folders: [ "/srv/data" ], operators: [ "test" ]), "/srv/data")

    Tenant.switch(@tenant) do
      Resource::Filesystem.create!(key: "pictures", details: { "folder" => "/Users/jon/Pictures" }, via: @mac)
      Resource::Filesystem.create!(key: "archive", details: { "folder" => "/srv/data" }, via: @media)
    end
  end

  test "move is a tool of its own, offered only to a token that may act on places" do
    listed = ->(scopes) { call(@tenant, scopes, "tools/list").dig("result", "tools").map { |held| held["name"] } }

    assert_includes listed.call(COMMAND), "move"
    refute_includes listed.call(%w[xixo:resources:read]), "move"

    schema = call(@tenant, COMMAND, "tools/list").dig("result", "tools").find { |held| held["name"] == "move" }["inputSchema"]
    assert_equal %w[from ids into path query run stop to type], schema["properties"].keys.sort
  end

  test "a move starts as a run on the folder the files go to, and the run answers how far it has come" do
    started = tool(@tenant, COMMAND, "move", from: "pictures", path: "2019", to: "archive", into: "Old")

    assert_equal "queued", started["status"]
    assert_equal 0, started.dig("moved", "files")
    assert_enqueued_jobs 1, only: PlanMoveJob

    Tenant.switch(@tenant) do
      run = Run.find(started["run"])
      assert_equal [ "move", "archive" ], [ run.kind, run.resource.key ]
      assert_equal [ "2019", "Old" ], run.selector.values_at("root", "into")
    end

    checked = tool(@tenant, COMMAND, "move", run: started["run"])
    assert_equal "queued", checked["status"]

    stopped = tool(@tenant, COMMAND, "move", run: started["run"], stop: true)
    assert_equal "cancelled", stopped["status"]
  end

  test "a folder shared read-only refuses the move and names the folder to share writable" do
    Tenant.switch(@tenant) do
      held = Resource::Machine.find(@mac.id)
      held.update!(details: held.details.merge("machine" => held.machine.merge("writable" => [])))
    end

    reply = call(@tenant, COMMAND, "tools/call", name: "move", arguments: { from: "pictures", to: "archive" })

    assert reply.dig("result", "isError")
    assert_match(%r{mac shares /Users/jon/Pictures read-only}, reply.dig("result", "content", 0, "text"))
    assert_match(%r{/Users/jon/Pictures:rw}, reply.dig("result", "content", 0, "text"))
    Tenant.switch(@tenant) { assert_equal 0, Run.count }
  end

  test "only an operator of both machines moves files" do
    Tenant.switch(@tenant) do
      held = Resource::Machine.find(@media.id)
      held.update!(details: held.details.merge("operators" => [ "someone-else" ]))
    end

    reply = call(@tenant, COMMAND, "tools/call", name: "move", arguments: { from: "pictures", to: "archive" })

    assert reply.dig("result", "isError")
    assert_match(/only an operator of media/, reply.dig("result", "content", 0, "text"))
  end

  test "a move needs a place to go, and the resource tool no longer moves" do
    reply = call(@tenant, COMMAND, "tools/call", name: "move", arguments: { from: "pictures" })
    assert reply.dig("result", "isError")
    assert_match(/move needs to/, reply.dig("result", "content", 0, "text"))

    reply = call(@tenant, COMMAND, "tools/call", name: "resource", arguments: { key: "archive", do: "move" })
    assert reply.dig("result", "isError") || reply["error"]
  end

  private

    def writing(machine, folder)
      Tenant.switch(@tenant) do
        held = Resource::Machine.find(machine.id)
        held.update!(details: held.details.merge(
          "machine" => held.machine.merge("writable" => [ folder ], "tools" => Resource::Machine::Tools::NAMES, "lend" => true)
        ))
        held
      end
    end
end
