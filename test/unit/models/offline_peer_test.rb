require "test_helper"
require_relative "../../support/fake_tailscaled"

class OfflinePeerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SEEN = Time.utc(2026, 10, 9, 18, 30)

  setup do
    @tailscaled = FakeTailscaled.new(peers: [
      FakeTailscaled.peer("nas", "100.64.1.2", online: false, last_seen: SEEN),
      FakeTailscaled.peer("studio", "100.64.1.3")
    ])
    ENV["XIXO_TAILSCALE_SOCKET"] = @tailscaled.path

    @tenant = Tenant.create!(subdomain: "offline-#{SecureRandom.hex(4)}", name: "Offline")
    Tenant.switch(@tenant) do
      @tailnet = Resource::Tailnet.create!(key: "tailnet", name: "Tailnet")
      @shares = Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }, via: @tailnet)
    end
  end

  teardown do
    ENV.delete("XIXO_TAILSCALE_SOCKET")
    @tailscaled.stop
  end

  test "a tailnet's nodes carry their names, addresses, and whether they are online, and nothing else" do
    nodes = Tenant.switch(@tenant) { @tailnet.nodes }

    assert_equal %w[studio nas], nodes.map { |node| node["host_name"] }
    assert_equal({ "host_name" => "nas", "dns_name" => "nas.tail0000.ts.net",
                   "addresses" => [ "100.64.1.2", "fd7a:115c:a1e0::2" ], "online" => false,
                   "last_seen" => SEEN.iso8601 }, nodes.last)
    assert_nil nodes.first["last_seen"]
    refute_match(/nodekey|tag:server|linux|41641|tor/, nodes.to_json)
  end

  test "a node is left out when tailscaled names nothing it could be reached at, and an address off the tailnet is dropped" do
    @tailscaled.peers = [
      { "PublicKey" => "nodekey:x", "HostName" => "", "TailscaleIPs" => [ "10.0.0.5" ] },
      { "PublicKey" => "nodekey:y", "HostName" => "bad name; rm", "TailscaleIPs" => [ "8.8.8.8", "100.64.9.9" ] }
    ]

    nodes = Tenant.switch(@tenant) { @tailnet.nodes }

    assert_equal [ { "host_name" => nil, "dns_name" => nil, "addresses" => [ "100.64.9.9" ], "online" => false, "last_seen" => nil } ], nodes
  end

  test "a resource on a peer that is offline is offline, and its check never dials it" do
    Tenant.switch(@tenant) do
      refute @shares.check

      @shares.reload
      assert @shares.offline?
      assert_nil @shares.check_error
      assert_equal "nas", @shares.offline_host
      assert_equal SEEN, @shares.offline_last_seen_at
      assert @shares.down?
      refute @shares.healthy?
      assert_equal "nas is offline on tailnet, last seen 2026-10-09T18:30:00Z", @shares.offline_reason
    end
  end

  test "a peer is matched by its name on the tailnet as well as its address" do
    Tenant.switch(@tenant) do
      %w[http://nas/dav/ http://NAS.tail0000.ts.net./dav/ http://[fd7a:115c:a1e0::2]/dav/].each do |url|
        @shares.update_columns(details: { "url" => url }, offline_host: nil)

        refute @shares.check, url
        assert @shares.reload.offline?, url
      end
    end
  end

  test "a resource reached directly is never offline, whatever tailscaled says" do
    Tenant.switch(@tenant) do
      direct = Resource::Webdav.create!(key: "direct", details: { "url" => "http://100.64.1.2/dav/" })

      refute direct.check
      refute direct.reload.offline?
      assert_match(/not a public address/, direct.check_error)
    end
  end

  test "a resource on a peer that is online is checked as before" do
    Tenant.switch(@tenant) do
      @shares.update_columns(details: { "url" => "http://100.64.1.3/dav/" })

      refute @shares.check
      refute @shares.reload.offline?
      assert @shares.check_error.present?
    end
  end

  test "when the peer comes back the next check clears offline and its syncs resume at once" do
    Tenant.switch(@tenant) do
      @shares.update!(sync_interval: 1.hour)
      @shares.update_columns(next_sync_at: 50.minutes.from_now)
      @shares.check
      assert @shares.reload.offline?

      @tailscaled.peers = [ FakeTailscaled.peer("nas", "100.64.1.2") ]
      @shares.check

      @shares.reload
      refute @shares.offline?
      assert_nil @shares.offline_last_seen_at
      assert_operator @shares.next_sync_at, :<=, Time.current
      assert_includes Resource.due_for_sync, @shares
    end
  end

  test "a scheduled sync waits while its peer is offline" do
    Tenant.switch(@tenant) do
      @shares.update!(sync_interval: 1.hour)
      @shares.update_columns(next_sync_at: 1.minute.ago)
      @shares.check
    end

    assert_no_enqueued_jobs(only: SyncResourceJob) { ScheduleSyncsJob.perform_now }
  end

  test "a resource that is offline is checked again on the failing schedule" do
    Tenant.switch(@tenant) do
      @shares.check
      refute_includes Resource.due_for_check, @shares

      @shares.update_columns(checked_at: (Resource::FAILING_CHECKED_EVERY + 1.minute).ago)
      assert_includes Resource.due_for_check, @shares
    end
  end

  test "a sync that meets a peer that is offline fails once, says why, and is not retried" do
    run = Tenant.switch(@tenant) do
      @shares.claim_sync!
      Run.start!(kind: "sync", resource: @shares)
    end

    assert_no_enqueued_jobs(only: SyncResourceJob) do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @shares.id, run.id) }
    end

    Tenant.switch(@tenant) do
      assert_equal "failed", run.reload.status
      assert_match(/Resource::Offline: nas is offline on tailnet/, run.error)
      assert @shares.reload.offline?
      refute @shares.syncing?
    end
  end

  test "a model server that is offline is passed over for one that answers" do
    Tenant.switch(@tenant) do
      models = { "fast" => "gemma3:4b" }
      away = Resource::OpenaiCompatible.create!(key: "away", details: { "base_url" => "http://100.64.1.2:11434/v1", "models" => models }, via: @tailnet)
      here = Resource::OpenaiCompatible.create!(key: "here", details: { "base_url" => "http://127.0.0.1:1/v1", "models" => models })
      away.make_default_inference!
      away.update_columns(offline_host: "nas", checked_at: Time.current)

      assert_equal here, Resource.for_role(:fast)
    end
  end

  test "discovery offers each node, and the well-known services that answer on the ones online" do
    knocked = []
    listening = lambda do |address, port|
      knocked << [ address, port ]
      port == 11_434
    end

    Resource::Tailnet.singleton_class.alias_method(:really_listening?, :listening?)
    Resource::Tailnet.define_singleton_method(:listening?, &listening)

    nodes = Tenant.switch(@tenant) { @tailnet.discovered(services: true) }

    assert_equal [ [ "100.64.1.3", 993 ], [ "100.64.1.3", 1234 ], [ "100.64.1.3", 11_434 ] ], knocked.sort
    assert_equal [ { "name" => "ollama", "port" => 11_434, "type" => "openai-compatible", "address" => "http://100.64.1.3:11434/v1" } ],
                 nodes.first["services"]
    assert_empty nodes.last["services"]
  ensure
    Resource::Tailnet.singleton_class.alias_method(:listening?, :really_listening?)
  end

  test "a type says where a node's address goes in its own settings" do
    assert_equal "url", Resource::Webdav.addressed_by
    assert_equal "http://100.64.1.2/", Resource::Webdav.address_on("100.64.1.2")
    assert_equal "host", Resource::Imap.addressed_by
    assert_equal "100.64.1.2", Resource::Imap.address_on("100.64.1.2")
    assert_equal "http://[fd7a:115c:a1e0::2]:11434/v1", Resource::OpenaiCompatible.address_on("fd7a:115c:a1e0::2", port: 11_434)
    assert_nil Resource::Weather.addressed_by
  end
end
