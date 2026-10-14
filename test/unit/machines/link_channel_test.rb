require "test_helper"
require_relative "../../support/machines"

class LinkChannelTest < ActionCable::Channel::TestCase
  include ActiveJob::TestHelper
  include Machines

  tests LinkChannel

  HELLO = {
    "version" => "0.2.0", "os" => "linux", "arch" => "arm64", "hostname" => "box",
    "folders" => [ "/srv/media", "/srv/photos" ],
    "services" => [ { "kind" => "ollama", "port" => 11_434, "address" => "100.64.0.9" } ]
  }.freeze

  HEALTH = {
    "uptime" => 3600.5, "load" => [ 0.1, 0.2, 0.3 ], "memory" => { "total" => 8_000_000_000, "available" => 4_000_000_000 },
    "disks" => [ { "path" => "/srv/media", "total" => 1_000_000, "free" => 500_000 } ]
  }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "links-#{SecureRandom.hex(4)}", name: "Links")
    @machine = machine_on(@tenant, connected: false)
  end

  test "only a machine subscribes, and it hears its own stream" do
    stub_connection(tenant: @tenant, grant: nil, machine: nil)
    subscribe
    assert subscription.rejected?

    connected
    assert subscription.confirmed?
    assert_has_stream_for @machine
  end

  test "a person's socket cannot join the GraphQL channel as a machine, nor a machine's the GraphQL one" do
    stub_connection(tenant: @tenant, grant: nil, machine: @machine, client_id: @machine.client_id)
    subscription = GraphqlChannel.new(connection, "{}", { "channel" => "GraphqlChannel" })
    subscription.subscribe_to_channel

    assert subscription.send(:subscription_rejected?)
  end

  test "hello records the machine and brings it online, and health is kept beside it" do
    Tenant.switch(@tenant) { @machine.update_columns(offline_host: "box", offline_last_seen_at: 1.day.ago) }
    connected

    perform :hello, HELLO.merge("hostname" => "box\u0007", "folders" => [ "/srv/media", "relative", "/srv/../etc", 5 ],
                                "services" => HELLO["services"] + [ { "kind" => "sshd", "port" => 22 } ])
    perform :health, HEALTH.merge("load" => [ 0.1, "high", -1 ])

    held = fresh
    assert held.connected?
    assert_not held.offline?
    assert_equal "box", held.machine["hostname"]
    assert_equal [ "/srv/media" ], held.offered_folders
    assert_equal [ "ollama" ], held.machine["services"].map { |service| service["kind"] }
    assert_equal [ 0.1, nil, nil ], held.machine.dig("health", "load")
    assert_equal 8_000_000_000, held.machine.dig("health", "memory", "total")
  end

  test "hello and health carry the machine's warnings, its tools, and whether it lends, kept plain and few" do
    connected

    perform :hello, HELLO.merge("warnings" => [ "may not read /srv/photos\u0007\nat all", 7, "x" * 900 ] + Array.new(30) { |index| "w#{index}" },
                                "tools" => %w[browse shell read], "lend" => true)

    held = fresh
    assert_equal "may not read /srv/photos at all", held.warnings.first
    assert_equal 500, held.warnings.second.size
    assert_equal 16, held.warnings.size
    assert_equal %w[browse read], held.offered_tools
    assert held.lends?

    perform :hello, HELLO.merge("lend" => false)
    assert_not fresh.lends?

    perform :health, HEALTH.merge("warnings" => [ "the shared folder /srv/photos does not exist" ])
    assert_equal [ "the shared folder /srv/photos does not exist" ], fresh.warnings

    perform :health, HEALTH
    assert_empty fresh.warnings
  end

  test "a change names the paths of a folder looked at again, and an overflow walks the whole folder" do
    connected
    perform :hello, HELLO
    media = Tenant.switch(@tenant) do
      Resource::Filesystem.create!(key: "on-demand", details: { "folder" => "/srv/media" }, via: @machine)
      Resource::Filesystem.create!(key: "media", details: { "folder" => "/srv/media" }, via: @machine, sync_interval: 3600)
    end

    perform :changed, "folder" => "/srv/media", "paths" => [ "a/b.txt", "../etc/passwd", "/etc/passwd", "a//c", 5, "a/b.txt" ]

    assert_equal [ [ @tenant.id, media.id, [ "a/b.txt" ] ] ],
                 enqueued_jobs.select { |job| job["job_class"] == "SyncPathsJob" }.map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }

    assert_no_enqueued_jobs(only: [ SyncPathsJob, SyncResourceJob ]) do
      perform :changed, "folder" => "/etc", "paths" => [ "passwd" ]
      perform :changed, "folder" => "/srv/media", "paths" => "a/b.txt"
    end

    assert_enqueued_with(job: SyncResourceJob) do
      perform :changed, "folder" => "/srv/media", "paths" => [], "overflow" => true
    end
  end

  test "leaving takes the machine offline, unless a newer connection took its place" do
    connected
    perform :hello, HELLO
    newer = LinkChannel.new(connection, "{}", { "channel" => "LinkChannel" })
    newer.subscribe_to_channel
    newer.perform_action("action" => "hello", **HELLO)

    unsubscribe
    assert fresh.connected?

    newer.unsubscribe_from_channel
    held = fresh
    assert_not held.connected?
    assert held.offline?
    assert_equal "box", held.offline_host
  end

  test "a question goes out on the machine's stream and its reply comes back" do
    connected
    perform :hello, HELLO

    answered = asking(fresh) do |asked|
      assert_equal "list", asked["verb"]
      assert_equal({ "folder" => "/srv/media" }, asked["args"])
      perform :reply, "request" => asked["request"], "ok" => true, "result" => { "entries" => [] }
    end
    answered = Tenant.switch(@tenant) { answered.ask("list", { "folder" => "/srv/media" }) }

    assert_equal({ "entries" => [] }, answered)
    assert_equal 0, Tenant.switch(@tenant) { LinkExchange.count }
  end

  test "a refusal comes back as a failure" do
    connected
    perform :hello, HELLO

    machine = asking(fresh) { |asked| perform :reply, "request" => asked["request"], "ok" => false, "error" => "no such file" }

    error = assert_raises(Resource::Failed) { Tenant.switch(@tenant) { machine.ask("read", {}) } }
    assert_match(/no such file/, error.message)
  end

  test "a question nobody answers fails at its deadline" do
    connected
    perform :hello, HELLO

    error = assert_raises(Resource::Failed) { Tenant.switch(@tenant) { fresh.ask("health", {}, within: 0.2.seconds) } }
    assert_match(/did not answer health/, error.message)
  end

  test "a machine that is not connected is not asked" do
    assert_raises(Resource::Offline) { Tenant.switch(@tenant) { fresh.ask("health") } }
  end

  test "a reply to another machine's question is ignored" do
    other = machine_on(@tenant, key: "other", connected: true)
    connected
    perform :hello, HELLO

    exchange = Tenant.switch(@tenant) { LinkExchange.create!(resource: other, request: SecureRandom.uuid, verb: "health") }
    perform :reply, "request" => exchange.request, "ok" => true, "result" => { "stolen" => true }

    assert_equal "asked", Tenant.switch(@tenant) { exchange.reload.status }
  end

  test "a read gathers chunks in order however they arrive" do
    connected
    perform :hello, HELLO
    body = SecureRandom.random_bytes(700)
    parts = [ body[0, 300], body[300, 300], body[600, 100] ]

    machine = asking(fresh) do |asked|
      perform :reply, "request" => asked["request"], "ok" => true, "result" => { "size" => body.bytesize }
      [ 2, 0, 1 ].each do |seq|
        perform :chunk, "request" => asked["request"], "seq" => seq, "data" => Base64.strict_encode64(parts[seq])
      end
    end

    file = Tenant.switch(@tenant) { machine.read("/srv/media", "a/b.bin") }
    assert_equal body, file.read
    assert_equal 0, Tenant.switch(@tenant) { LinkChunk.count }
  ensure
    file&.close!
  end

  test "a chunk that is not base64 or is too large refuses the read" do
    connected
    perform :hello, HELLO

    machine = asking(fresh) do |asked|
      perform :reply, "request" => asked["request"], "ok" => true, "result" => { "size" => 10 }
      perform :chunk, "request" => asked["request"], "seq" => 0, "data" => "not base64!"
      perform :chunk, "request" => asked["request"], "seq" => 1,
                      "data" => Base64.strict_encode64("x" * (Resource::Machine::MOST_CHUNKED + 1))
    end

    assert_raises(Resource::Failed) { Tenant.switch(@tenant) { machine.read("/srv/media", "big.bin") } }
  end

  test "hello is answered by asking the machine for every tool and for lending, and its config narrows that alone" do
    connected
    stream = LinkChannel.broadcasting_for(@machine)

    perform :hello, HELLO.merge("services" => [ { "kind" => "ollama", "port" => 11_434 } ])

    told = ActionCable.server.pubsub.broadcasts(stream).map { |held| JSON.parse(held) }
    assert_equal [ { "settings" => { "tools" => %w[browse search read write extract models], "lend" => true,
                                     "extracts_for_others" => true } } ], told
  end

  test "an upload is held for the machine to fetch and never goes out on the stream" do
    connected
    perform :hello, HELLO
    body = SecureRandom.random_bytes(Resource::Machine::MOST_CHUNKED + 10)
    stream = LinkChannel.broadcasting_for(@machine)
    ActionCable.server.pubsub.clear_messages(stream)

    staged = Tenant.switch(@tenant) { fresh.upload(StringIO.new(body)) }

    assert_equal body.bytesize, staged["size"]
    assert_empty ActionCable.server.pubsub.broadcasts(stream)

    Tenant.switch(@tenant) do
      exchange = LinkExchange.taken!(fresh, staged["upload"])
      sent = +""
      LinkExchange::Sending.new(exchange).each { |part| sent << part }

      assert_equal body, sent
      assert_equal 0, LinkChunk.count
      assert_nil LinkExchange.taken!(fresh, staged["upload"]), "an upload is served once"

      fresh.forget(staged["upload"])
      assert_equal 0, LinkExchange.count
    end
  end

  test "a machine cannot add chunks to an upload xixo staged" do
    connected
    perform :hello, HELLO

    staged = Tenant.switch(@tenant) { fresh.upload(StringIO.new("twelve bytes")) }
    perform :chunk, "request" => staged["upload"], "seq" => 1, "data" => Base64.strict_encode64("planted")

    assert_equal 1, Tenant.switch(@tenant) { LinkChunk.count }
  end

  test "a file's chunks are kept when they arrive after the reply, in any order" do
    connected
    perform :hello, HELLO
    thumbnail = SecureRandom.random_bytes(400)
    file_id = SecureRandom.uuid

    machine = asking(fresh) do |asked|
      perform :reply, "request" => asked["request"], "ok" => true, "result" => {
        "files" => [ { "role" => "thumbnail", "name" => "t.jpg", "size" => 400, "request_file" => file_id } ]
      }
      perform :chunk, "request" => file_id, "of" => asked["request"], "seq" => 1, "data" => Base64.strict_encode64(thumbnail[300..])
      perform :chunk, "request" => file_id, "of" => asked["request"], "seq" => 0, "data" => Base64.strict_encode64(thumbnail[0, 300])
    end

    kept = Tenant.switch(@tenant) do
      machine.exchanged("extract", {}) { |answer| answer.file(answer.files.first).then { |file| file.read.tap { file.close! } } }
    end

    assert_equal thumbnail, kept
  end

  test "a file named twice is one file" do
    connected
    perform :hello, HELLO

    Tenant.switch(@tenant) do
      parent = LinkExchange.create!(resource: @machine, request: SecureRandom.uuid, verb: "extract")
      file_id = SecureRandom.uuid

      first = LinkExchange.receiving(@machine, file_id, of: parent.request)
      again = LinkExchange.receiving(@machine, file_id, of: parent.request)

      assert_equal first, again
      assert_equal 1, parent.files.count
    end
  end

  test "a chunk numbered past what can be kept refuses the read" do
    connected
    perform :hello, HELLO

    exchange = Tenant.switch(@tenant) { LinkExchange.create!(resource: @machine, request: SecureRandom.uuid, verb: "read") }
    perform :chunk, "request" => exchange.request, "seq" => 2**31, "data" => Base64.strict_encode64("x")

    assert_equal "refused", Tenant.switch(@tenant) { exchange.reload.status }
  end

  test "a machine with too many questions open is not asked another" do
    connected
    perform :hello, HELLO

    Tenant.switch(@tenant) do
      LinkExchange::MOST_OPEN.times { LinkExchange.create!(resource: @machine, request: SecureRandom.uuid, verb: "list") }

      assert_raises(Resource::Failed) { fresh.ask("health") }
    end
  end

  test "hanging up after the machine is put away takes it offline" do
    connected
    perform :hello, HELLO

    Tenant.switch(@tenant) { fresh.update_columns(archived_at: Time.current) }
    unsubscribe

    Tenant.switch(@tenant) { assert_not fresh.connected? }
  end

  test "a client the machine was enrolled again past is shut out at its next message and at the next sweep" do
    connected
    perform :hello, HELLO
    closed = closing

    Tenant.switch(@tenant) { fresh.update_columns(details: fresh.details.merge("client_id" => "link-newer")) }
    perform :health, HEALTH

    assert_nil fresh.machine["health"]
    assert_equal [ { reason: "unknown_machine", reconnect: false } ], closed

    subscription.send(:expire)
    assert_equal [ { reason: "unknown_machine", reconnect: false } ] * 2, closed
  end

  test "a client the machine no longer names cannot subscribe" do
    stub_connection(tenant: @tenant, grant: nil, machine: @machine, client_id: "link-older")
    subscribe

    assert subscription.rejected?
  end

  test "the sweep lets the current client stay, and asks an expired one to sign in again" do
    connected
    closed = closing
    expired = false
    connection.define_singleton_method(:expired?) { expired }

    subscription.send(:expire)
    assert_empty closed

    expired = true
    subscription.send(:expire)
    assert_equal [ { reason: "unauthorized", reconnect: true } ], closed
  end

  test "an answer names files xixo link streamed back under their own ids" do
    connected
    perform :hello, HELLO
    thumbnail = SecureRandom.random_bytes(400)
    file_id = SecureRandom.uuid

    machine = asking(fresh) do |asked|
      perform :chunk, "request" => file_id, "of" => asked["request"], "seq" => 1, "data" => Base64.strict_encode64(thumbnail[300..])
      perform :chunk, "request" => file_id, "of" => asked["request"], "seq" => 0, "data" => Base64.strict_encode64(thumbnail[0, 300])
      perform :reply, "request" => asked["request"], "ok" => true, "result" => {
        "steps" => { "text" => { "result" => "hello" } },
        "files" => [ { "role" => "thumbnail", "name" => "t.webp", "size" => 400, "request_file" => file_id },
                     { "role" => "preview", "name" => "empty", "size" => 0, "request_file" => SecureRandom.uuid } ]
      }
    end

    kept = Tenant.switch(@tenant) do
      machine.exchanged("extract", { "source" => { "upload" => SecureRandom.uuid } }) do |answer|
        assert_equal "hello", answer.result.dig("steps", "text", "result")
        answer.files.map { |entry| answer.file(entry).then { |file| file.read.tap { file.close! } } }
      end
    end

    assert_equal [ thumbnail, "" ], kept
    assert_equal 0, Tenant.switch(@tenant) { LinkExchange.count + LinkChunk.count }
  end

  test "a file chunk needs an open question of this machine as its parent" do
    other = machine_on(@tenant, key: "other", connected: true)
    connected
    perform :hello, HELLO
    theirs = Tenant.switch(@tenant) { LinkExchange.create!(resource: other, request: SecureRandom.uuid, verb: "extract") }

    perform :chunk, "request" => SecureRandom.uuid, "seq" => 0, "data" => Base64.strict_encode64("x")
    perform :chunk, "request" => SecureRandom.uuid, "of" => SecureRandom.uuid, "seq" => 0, "data" => Base64.strict_encode64("x")
    perform :chunk, "request" => SecureRandom.uuid, "of" => theirs.request, "seq" => 0, "data" => Base64.strict_encode64("x")

    assert_equal 1, Tenant.switch(@tenant) { LinkExchange.count }
    assert_equal 0, Tenant.switch(@tenant) { LinkChunk.count }
  end

  private

    def connected
      stub_connection(tenant: @tenant, grant: nil, machine: @machine, client_id: @machine.client_id)
      subscribe
    end

    def closing
      closed = []
      connection.define_singleton_method(:close) { |**options| closed << options }
      connection.define_singleton_method(:expired?) { false } unless connection.respond_to?(:expired?)
      closed
    end

    def fresh
      Tenant.switch(@tenant) { Resource::Machine.find(@machine.id) }
    end

    def asking(machine)
      stream = LinkChannel.broadcasting_for(machine)
      answered = false

      machine.define_singleton_method(:waiting) do
        next if answered

        answered = true
        yield JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last)
      end

      machine
    end
end
