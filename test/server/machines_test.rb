require "test_helper"
require_relative "../support/machines"

class MachinesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Machines

  ATTACH = <<~GQL.freeze
    mutation($settings: JSON, $personal: Boolean) {
      attachResource(input: { type: "machine", key: "box", name: "Box", settings: $settings, personal: $personal }) {
        resource { key settings heldCredentials machine { connected folders } }
      }
    }
  GQL

  SETTINGS = {
    "host" => "100.64.0.9", "user" => "jon", "host_key" => "SHA256:#{'A' * 43}", "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----",
    "folders" => "/srv/media\n/srv/My Photos\n"
  }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "machines-#{SecureRandom.hex(4)}", name: "Machines")
    connect!(@tenant)
  end

  test "only an administrator attaches a machine, and never as only theirs" do
    member = graphql(Grant::SIGN_IN, ATTACH, settings: SETTINGS)
    assert_match(/only an administrator/, member.dig("errors", 0, "message"))

    personal = graphql(Grant::SCOPES, ATTACH, settings: SETTINGS, personal: true)
    assert_match(/an administrator attaches for everyone/, personal.dig("errors", 0, "message"))

    Tenant.switch(@tenant) { assert_not Resource::Machine.exists? }
    assert_no_enqueued_jobs(only: InstallLinkJob)
  end

  test "attaching a machine with a key starts an install, keeps the key out of sight, and splits folders by line" do
    attached = nil

    assert_enqueued_with(job: InstallLinkJob) do
      attached = graphql(Grant::SCOPES, ATTACH, settings: SETTINGS).dig("data", "attachResource", "resource")
    end

    assert_equal [ "/srv/media", "/srv/My Photos" ], attached.dig("settings", "folders")
    assert_not attached["settings"].key?("private_key")
    assert_equal [ "private_key" ], attached["heldCredentials"]
    assert_equal false, attached.dig("machine", "connected")

    Tenant.switch(@tenant) { assert_equal [ "install" ], Run.where(resource: Resource.find_by!(key: "box")).pluck(:kind) }
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
      machine.update_columns(details: machine.details.deep_merge("machine" => { "extractors" => %w[text pdf], "tools" => %w[read shell browse], "lend" => true }))
    end

    body = graphql(Grant::SCOPES, "{ resources { key machine { extractors unread lends tools } } }")

    held = body.dig("data", "resources").find { |listed| listed["key"] == "box" }["machine"]
    assert_equal %w[text pdf], held["extractors"]
    assert_equal Resource::Machine::EXTRACTORS - %w[text pdf], held["unread"]
    assert_equal true, held["lends"]
    assert_equal %w[browse read], held["tools"]
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

  test "an admin turns lending on for a machine's next install without touching what it learned at install" do
    machine = machine_on(@tenant, folders: [ "/srv/media" ])

    body = graphql(Grant::SCOPES, <<~GQL)
      mutation { updateResource(input: { id: "#{machine.id}", settings: { lend: true } }) { resource { key } } }
    GQL

    assert_nil body["errors"]
    Tenant.switch(@tenant) do
      held = machine.reload
      assert_equal true, held.details["lend"]
      assert_not held.lends?
      assert_equal [ "/srv/media" ], held.details["folders"]
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
      box.update_columns(details: box.details.deep_merge("machine" => { "services" => [ { "kind" => "ollama", "port" => 11434, "address" => "100.64.0.9" } ] }))
      local = Resource::Machine.local!
      tailnet = Resource::Tailnet.create!(key: "home", name: "home")
      Resource::Filesystem.create!(key: "media", via: box, details: { "folder" => "/srv/media" })
      Resource::OpenaiCompatible.create!(key: "ollama-box", via: tailnet, details: { "base_url" => "http://100.64.0.9:11434/v1" })
      Resource::OpenaiCompatible.create!(key: "elsewhere", via: tailnet, details: { "base_url" => "http://100.64.0.77:11434/v1" })
      { box: box.id.to_s, local: local.id.to_s }
    end

    body = graphql(Grant::SCOPES, "{ resources { key machineId machine { services { kind port url via } } } }")
    on = body.dig("data", "resources").to_h { |resource| [ resource["key"], resource["machineId"] ] }

    assert_equal({ "box" => nil, "local" => nil, "media" => held[:box], "ollama-box" => held[:box],
                   "elsewhere" => held[:local], "home" => held[:local] }, on.slice("box", "local", "media", "ollama-box", "elsewhere", "home"))
    assert_equal [ { "kind" => "ollama", "port" => 11434, "url" => "http://100.64.0.9:11434/v1", "via" => "home" } ],
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
