require "test_helper"
require_relative "../../support/fake_tailscaled"

class TailnetTest < ActiveSupport::TestCase
  RANGES = Resource::Tailnet::RANGES

  setup do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
    @tenant = Tenant.create!(subdomain: "tailnet-#{SecureRandom.hex(4)}", name: "Tailnet")
    @tailnet = Tenant.switch(@tenant) { Resource::Tailnet.create!(key: "tailnet", name: "Tailnet") }
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
    ENV.delete("XIXO_TAILSCALE_SOCKET")
    ENV.delete("XIXO_GIT_PROTOCOLS")
    @tailscaled&.stop
  end

  test "an address on the tailnet is reached through it and refused without it" do
    assert_equal "100.64.1.2", PublicAddress.address_for!("100.64.1.2", through: RANGES)
    assert_equal "fd7a:115c:a1e0::5", PublicAddress.address_for!("fd7a:115c:a1e0::5", through: RANGES)

    assert_raises(PublicAddress::Blocked) { PublicAddress.address_for!("100.64.1.2") }
  end

  test "a transport reaches only what it covers, public addresses included" do
    %w[127.0.0.1 10.0.0.5 192.168.1.1 169.254.169.254 8.8.8.8 ::1 ::ffff:127.0.0.1].each do |address|
      assert_raises(PublicAddress::Blocked, address) { PublicAddress.address_for!(address, through: RANGES) }
    end
  end

  test "allowing private fetches everywhere does not widen a transport" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    assert_raises(PublicAddress::Blocked) { PublicAddress.permitted!("http://10.0.0.5/", through: RANGES) }
    assert PublicAddress.permitted!("http://100.100.1.1/", through: RANGES)
  end

  test "an address on the tailnet wearing an IPv6 costume is still on the tailnet" do
    assert PublicAddress.covered?(IPAddr.new("::ffff:100.64.0.9"), RANGES)
  end

  test "a tailnet is declared by the deployment and never attached by hand" do
    refute_includes Resource.attachable, Resource::Tailnet

    Tenant.switch(@tenant) do
      declared = Resource.declare!("home" => { "type" => "tailnet", "name" => "Home" }).first

      assert_instance_of Resource::Tailnet, declared
      assert declared.transport?
    end
  end

  test "a tailscaled socket in the environment declares the tailnet in every tenant" do
    assert_not_includes Resource.declarations.keys, "tailnet"

    ENV["XIXO_TAILSCALE_SOCKET"] = "/var/run/tailscale/tailscaled.sock"

    assert_equal({ "type" => "tailnet", "name" => "Tailnet" }, Resource.declarations["tailnet"])
  end

  test "a declaration names the transport a resource is reached through" do
    Tenant.switch(@tenant) do
      declared = Resource.declare!(
        "shares" => { "type" => "webdav", "via" => "tailnet", "settings" => { "url" => "http://100.64.1.2/dav/" } }
      ).first

      assert_equal @tailnet, declared.via
    end
  end

  test "the check asks tailscaled for its status over the local socket" do
    @tailscaled = FakeTailscaled.new
    ENV["XIXO_TAILSCALE_SOCKET"] = @tailscaled.path

    Tenant.switch(@tenant) { assert @tailnet.check }

    asked = @tailscaled.asked.pop

    assert_match %r{\AGET /localapi/v0/status HTTP/1\.0\r\n}, asked
    assert_includes asked, "Host: local-tailscaled.sock"
  end

  test "a tailnet that is not running fails its check with the state tailscaled names" do
    @tailscaled = FakeTailscaled.new(state: "NeedsLogin")
    ENV["XIXO_TAILSCALE_SOCKET"] = @tailscaled.path

    Tenant.switch(@tenant) do
      refute @tailnet.check
      assert_match(/tailscaled is NeedsLogin/, @tailnet.reload.check_error)
    end
  end

  test "a tailscaled that answers with an error fails the check" do
    @tailscaled = FakeTailscaled.new(answer: "HTTP/1.0 403 Forbidden\r\n\r\nno")
    ENV["XIXO_TAILSCALE_SOCKET"] = @tailscaled.path

    Tenant.switch(@tenant) do
      refute @tailnet.check
      assert_match(/answered 403/, @tailnet.reload.check_error)
    end
  end

  test "a tailnet with no socket named, or none there, fails its check" do
    Tenant.switch(@tenant) do
      refute @tailnet.check
      assert_match(/XIXO_TAILSCALE_SOCKET names no tailscaled socket/, @tailnet.reload.check_error)

      ENV["XIXO_TAILSCALE_SOCKET"] = "/nonexistent/tailscaled.sock"

      refute @tailnet.check
      assert_match(/ENOENT/, @tailnet.reload.check_error)
    end
  end

  test "a resource behind a tailnet that is down says so before it dials" do
    Tenant.switch(@tenant) do
      shares = Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }, via: @tailnet)

      refute shares.check
      assert_match(/shares is reached through tailnet, which is down/, shares.reload.check_error)
    end
  end

  test "a type that dials its own way cannot be reached through a transport" do
    Tenant.switch(@tenant) do
      weather = Resource::Weather.new(key: "weather", details: { "provider" => "open-meteo" }, via: @tailnet)

      refute weather.valid?
      assert_includes weather.errors[:via].join, "dials its own way"
    end
  end

  test "webdav behind a tailnet dials an address on it and nothing else" do
    Tenant.switch(@tenant) do
      assert_equal "100.64.1.2", webdav("http://100.64.1.2/dav/").send(:pinned!, "http://100.64.1.2/dav/").address

      assert_raises(PublicFetch::Blocked) { webdav("http://10.0.0.5/dav/").send(:pinned!, "http://10.0.0.5/dav/") }
      assert_raises(PublicFetch::Blocked) { webdav("http://8.8.8.8/dav/").send(:pinned!, "http://8.8.8.8/dav/") }
    end
  end

  test "object storage behind a tailnet gets a client that checks the peer against the tailnet" do
    Tenant.switch(@tenant) do
      client = bucket("http://100.64.1.2:3900").send(:connection)

      assert_instance_of Resource::S3::PublicClient, client
      assert_equal RANGES, client.config.xixo_through

      assert_raises(PublicFetch::Blocked) { bucket("http://169.254.169.254").send(:connection) }
      assert_raises(PublicFetch::Blocked) { bucket("https://8.8.8.8").send(:connection) }
    end
  end

  test "object storage behind a tailnet is dropped when a peer off the tailnet answers" do
    server = TCPServer.new("127.0.0.1", 0)
    accepted = Thread.new { server.accept&.close }
    WebMock.disable!

    client = Resource::S3::PublicClient.new(
      endpoint: "http://127.0.0.1:#{server.addr[1]}", region: "us-east-1", access_key_id: "id",
      secret_access_key: "secret", force_path_style: true, retry_limit: 0, xixo_through: RANGES
    )

    error = assert_raises(PublicFetch::Blocked) { client.head_bucket(bucket: "bucket") }

    assert_match(/127\.0\.0\.1, which is not an address its transport reaches/, error.message)
  ensure
    WebMock.enable!
    accepted&.kill
    server&.close
  end

  test "mail behind a tailnet dials an address on it and nothing else" do
    Tenant.switch(@tenant) do
      assert_equal "100.64.1.2", mail("100.64.1.2").send(:address)
      assert_raises(PublicFetch::Blocked) { mail("10.0.0.5").send(:address) }
    end
  end

  test "a git remote behind a tailnet is http on the tailnet, never ssh" do
    ENV["XIXO_GIT_PROTOCOLS"] = "http,https,ssh"

    Tenant.switch(@tenant) do
      assert_equal "100.64.1.2", repository("http://100.64.1.2/repo.git").send(:permitted!).address

      error = assert_raises(Resource::Unusable) { repository("ssh://100.64.1.2/repo.git").send(:permitted!) }
      assert_match(/only an http or https url is reached through tailnet/, error.message)
    end
  end

  test "inference behind a tailnet is refused an address off it" do
    Tenant.switch(@tenant) do
      brain = Resource::OpenaiCompatible.new(
        key: "brain", details: { "base_url" => "http://10.0.0.5:11434/v1", "models" => { "fast" => "m" } }, via: @tailnet
      )

      error = assert_raises(Resource::Unusable) { brain.base_url }
      assert_match(/not an address its transport reaches/, error.message)
    end
  end

  private

    def webdav(url)
      Resource::Webdav.new(key: "shares", details: { "url" => url }, via: @tailnet)
    end

    def bucket(endpoint)
      Resource::S3.new(key: "bucket", details: { "endpoint" => endpoint },
                       credentials: { "access_key_id" => "id", "secret_access_key" => "secret" }, via: @tailnet)
    end

    def mail(host)
      Resource::Imap.new(key: "mail", details: { "host" => host }, via: @tailnet)
    end

    def repository(url)
      Resource::Git.new(key: "repo", details: { "url" => url }, via: @tailnet)
    end
end
