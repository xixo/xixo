require "test_helper"
require_relative "../support/machines"

class MachinesTest < ActionDispatch::IntegrationTest
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "machines-#{SecureRandom.hex(4)}", name: "Machines")
    connect!(@tenant)
  end

  test "a machine says what it shares, and its folders are offered to attach" do
    machine = machine_on(@tenant, folders: [ "/srv/media" ])

    body = graphql(Grant::SCOPES, <<~GQL)
      {
        resources { key machine { hostname connected folders } }
        discovered(via: "#{machine.key}") { hostName services { type address } address(type: "filesystem") }
      }
    GQL

    listed = body.dig("data", "resources").find { |held| held["key"] == "box" }
    assert_equal({ "hostname" => "box", "connected" => true, "folders" => [ "/srv/media" ] }, listed["machine"])
    assert_equal [ { "hostName" => "media", "services" => [ { "type" => "filesystem", "address" => "/srv/media" } ], "address" => nil } ],
                 body.dig("data", "discovered")
  end

  test "a machine says which kinds of file it reads, which it cannot, whether it lends its files, and which tools it offers" do
    machine = machine_on(@tenant, folders: [ "/srv/media" ])
    Tenant.switch(@tenant) do
      machine.update_columns(details: machine.details.deep_merge("machine" => { "extractors" => %w[text pdf], "lend" => true }))
    end

    body = graphql(Grant::SCOPES, "{ resources { key machine { extractors unread lends tools } } }")

    held = body.dig("data", "resources").find { |listed| listed["key"] == "box" }["machine"]
    assert_equal %w[text pdf], held["extractors"]
    assert_equal Resource::Machine::EXTRACTORS - %w[text pdf], held["unread"]
    assert_equal true, held["lends"]
    assert_equal %w[browse search read extract], held["tools"]
  end

  test "a machine says which shared folders xixo may write into, by what xixo link shares writable, and what its config keeps off" do
    machine = machine_on(@tenant, folders: [ "/srv/media", "/srv/inbox" ])
    Tenant.switch(@tenant) do
      machine.update_columns(details: machine.details.deep_merge("machine" => { "writable" => [ "/srv/inbox", "/etc" ], "lend" => false }))
    end
    asked = "{ resources { key machine { folders writable heldBack tools } } }"

    held = graphql(Grant::SCOPES, asked).dig("data", "resources").find { |listed| listed["key"] == "box" }["machine"]
    assert_equal [ "/srv/media", "/srv/inbox" ], held["folders"]
    assert_equal [ "/srv/inbox" ], held["writable"]
    assert_equal %w[lend], held["heldBack"]
    assert_equal %w[browse search read write extract], held["tools"]
  end

  test "files whose reading waits are counted on the machine they wait for, and apart when any machine will do" do
    machine = machine_on(@tenant, folders: [ "/srv/media" ])
    Tenant.switch(@tenant) do
      2.times { |n| Analysis.open!(feed: create_feed(key: "clip-#{n}"), cause: "sync").parked!(kind: "media", machine: machine) }
      Analysis.open!(feed: create_feed(key: "plan"), cause: "sync").parked!(kind: "pdf")
    end

    body = graphql(Grant::SCOPES, "{ waitingForMachines { kind count } resources { key machine { waiting { kind count } } } }")

    assert_equal [ { "kind" => "pdf", "count" => 1 } ], body.dig("data", "waitingForMachines")
    held = body.dig("data", "resources").find { |listed| listed["key"] == "box" }["machine"]
    assert_equal [ { "kind" => "media", "count" => 2 } ], held["waiting"]
  end

  test "an admin renames a machine and lists its operators without touching what xixo link said" do
    machine = machine_on(@tenant, folders: [ "/srv/media" ])

    body = graphql(Grant::SCOPES, <<~GQL, settings: { "operators" => "alice\ncarol" })
      mutation($settings: JSON) { updateResource(input: { id: "#{machine.id}", name: "Studio", settings: $settings }) { resource { key name } } }
    GQL

    assert_nil body["errors"]
    Tenant.switch(@tenant) do
      held = machine.reload
      assert_equal [ "box", "Studio" ], [ held.key, held.name ]
      assert_equal %w[alice carol], held.operators
      assert_equal [ "/srv/media" ], held.offered_folders
      assert held.client_id.present?
    end
  end

  test "a folder attaches through the machine and is refused when the machine does not share it" do
    machine_on(@tenant, folders: [ "/srv/media" ])
    attach = <<~GQL
      mutation($settings: JSON) {
        attachResource(input: { type: "filesystem", key: "media", settings: $settings, via: "box" }) {
          resource { key via }
        }
      }
    GQL

    refused = graphql(Grant::SCOPES, attach, settings: { "folder" => "/etc" })
    assert_match(%r{/etc is not one box shares}, refused.dig("errors", 0, "message"))

    attached = graphql(Grant::SCOPES, attach, settings: { "folder" => "/srv/media" })
    assert_equal({ "key" => "media", "via" => "box" }, attached.dig("data", "attachResource", "resource"))
  end

  test "each resource names the machine it lives on or is reached through, and this server holds the rest" do
    box = machine_on(@tenant, folders: [ "/srv/media" ])
    held = Tenant.switch(@tenant) do
      box.update_columns(details: box.details.deep_merge("machine" => { "services" => [ { "kind" => "ollama", "port" => 11434 } ] }))
      local = Resource::Machine.local!
      Resource::Filesystem.create!(key: "media", via: box, details: { "folder" => "/srv/media" })
      Resource::OpenaiCompatible.create!(key: "ollama-box", via: box, details: { "base_url" => "http://127.0.0.1:11434/v1" })
      Resource::OpenaiCompatible.create!(key: "elsewhere", details: { "base_url" => "http://192.0.2.77:11434/v1" })
      { box: box.id.to_s, local: local.id.to_s }
    end

    body = graphql(Grant::SCOPES, "{ resources { key machineId machine { services { kind port } } } }")
    on = body.dig("data", "resources").to_h { |resource| [ resource["key"], resource["machineId"] ] }

    assert_equal({ "box" => nil, "local" => nil, "media" => held[:box], "ollama-box" => held[:box],
                   "elsewhere" => held[:local] }, on.slice("box", "local", "media", "ollama-box", "elsewhere"))
    assert_equal [ { "kind" => "ollama", "port" => 11434 } ],
                 body.dig("data", "resources").find { |resource| resource["key"] == "box" }.dig("machine", "services")
  end

  test "only an administrator reaches a folder through a machine, even as only theirs" do
    machine_on(@tenant, folders: [ "/srv/media", "/home/jon" ])
    attach = <<~GQL
      mutation($settings: JSON) {
        attachResource(input: { type: "filesystem", key: "mine", settings: $settings, via: "box", personal: true }) {
          resource { key via }
        }
      }
    GQL

    refused = graphql(Grant::SIGN_IN, attach, settings: { "folder" => "/home/jon" })
    assert_match(/only an administrator reaches a folder through a machine/, refused.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_not Resource::Filesystem.exists? }

    attached = graphql(Grant::SCOPES, attach, settings: { "folder" => "/home/jon" })
    assert_equal({ "key" => "mine", "via" => "box" }, attached.dig("data", "attachResource", "resource"))
  end

  ARCHIVE = <<~GQL.freeze
    mutation($id: ID!) { archiveResource(input: { id: $id, archived: true }) { resource { key archivedAt } } }
  GQL

  test "putting a machine away unenrolls it in masks and hangs up on it at once" do
    machine = machine_on(@tenant, client_id: "link-gone")
    hung_up = []

    swapping(ActionCable.server, :remote_connections, -> { Hanging.new(hung_up) }) do
      archived = graphql(Grant::SCOPES, ARCHIVE, id: machine.id)

      assert archived.dig("data", "archiveResource", "resource", "archivedAt")
    end

    assert_equal [ { "subdomain" => @tenant.subdomain, "client_id" => "items-test-client", "machine" => "link-gone" } ],
                 issuer.unenrollments.select { |held| held["subdomain"] == @tenant.subdomain }
    assert_equal [ [ { tenant: @tenant, grant: nil, machine: machine, client_id: "link-gone" }, false ] ], hung_up

    Tenant.switch(@tenant) do
      held = machine.reload
      assert_nil held.client_id
      assert_equal "link-gone", held.details.dig("unenrolled", "client_id")
      assert_nil Resource::Machine.enrolled("link-gone")
    end
  end

  test "binding a machine to another client or unenrolling it hangs up the client it had, and only that one" do
    machine = machine_on(@tenant, client_id: "link-first")
    hung_up = []

    swapping(ActionCable.server, :remote_connections, -> { Hanging.new(hung_up) }) do
      Tenant.switch(@tenant) do
        machine.bound!("link-second", revoker: ->(*) { true })
        machine.update!(name: "Renamed")
        machine.unenroll!(revoker: ->(*) { true })
      end
    end

    assert_equal [ "link-first", "link-second" ], hung_up.map { |identifiers, _| identifiers[:client_id] }
    assert(hung_up.all? { |identifiers, reconnect| identifiers[:machine] == machine && !reconnect })
  end

  test "a machine stays attached while masks cannot be reached to unenroll it" do
    machine = machine_on(@tenant, client_id: "link-kept")

    swapping(Resource::Machine::Enrollment, :revoke, ->(*) { raise Resource::Failed, "masks could not be reached to unenroll the machine" }) do
      refused = graphql(Grant::SCOPES, ARCHIVE, id: machine.id)

      assert_match(/could not be reached.*stays attached/, refused.dig("errors", 0, "message"))
    end

    Tenant.switch(@tenant) do
      held = machine.reload
      assert_nil held.archived_at
      assert_equal "link-kept", held.client_id
    end
  end

  test "a machine that never enrolled is put away without asking masks" do
    machine = machine_on(@tenant, client_id: nil)

    archived = graphql(Grant::SCOPES, ARCHIVE, id: machine.id)

    assert archived.dig("data", "archiveResource", "resource", "archivedAt")
    assert_empty(issuer.unenrollments.select { |held| held["subdomain"] == @tenant.subdomain })
  end

  private

    Hanging = Struct.new(:held) do
      def where(**identifiers)
        @identifiers = identifiers
        self
      end

      def disconnect(reconnect: true)
        held << [ @identifiers, reconnect ]
      end
    end

    def swapping(holder, name, replacement)
      original = holder.method(name)
      holder.define_singleton_method(name) { |*args, **options, &block| replacement.call(*args, **options, &block) }
      yield
    ensure
      holder.define_singleton_method(name, original)
    end

    def graphql(scopes, query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}",
                                  "Content-Type" => "application/json" }

      response.parsed_body
    end
end
