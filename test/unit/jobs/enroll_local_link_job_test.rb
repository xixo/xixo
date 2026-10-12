require "test_helper"

class EnrollLocalLinkJobTest < ActiveSupport::TestCase
  setup do
    FakeLink.standing = false
    @tenant = Tenant.create!(subdomain: "local-#{SecureRandom.hex(4)}", name: "Local")
    connect!(@tenant)
    @root = Pathname.new(Dir.mktmpdir)
    @dir = @root.join(@tenant.subdomain).tap(&:mkpath)
    ENV["XIXO_LOCAL_LINK"] = @root.to_s
  end

  test "a tenant not yet connected to masks is passed over without minting" do
    @tenant.disconnect!
    @dir.join("wanted").write("")

    EnrollLocalLinkJob.perform_now

    assert_not @dir.join("token").exist?
  end

  teardown do
    ENV.delete("XIXO_LOCAL_LINK")
    FileUtils.rm_rf(@root)
  end

  test "a machine that wants enrolling is left a token only it can read" do
    @dir.join("wanted").write("")

    minting("first-token") { EnrollLocalLinkJob.perform_now }

    token = @dir.join("token")
    assert_equal "first-token", token.read
    assert_equal "600", format("%o", token.stat.mode & 0o777)
    Tenant.switch(@tenant) { assert Resource::Machine.local&.local? }
  end

  test "a fresh token is not replaced, and a stale one is" do
    @dir.join("wanted").write("")
    @dir.join("token").write("held")

    minting("second-token") { EnrollLocalLinkJob.perform_now }
    assert_equal "held", @dir.join("token").read

    File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, @dir.join("token"))
    minting("second-token") { EnrollLocalLinkJob.perform_now }
    assert_equal "second-token", @dir.join("token").read
  end

  test "a machine that wants nothing is left nothing" do
    minting("unasked") { EnrollLocalLinkJob.perform_now }

    assert_not @dir.join("token").exist?
  end

  test "the client xixo link enrolled as becomes xixo link beside the server" do
    handed_a_token
    @dir.join("client_id").write("local-client\n")

    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) { assert_equal "local-client", Resource::Machine.local.client_id }
  end

  test "a machine that enrolled again leaves its earlier client unenrolled in masks" do
    handed_a_token
    @dir.join("client_id").write("first-client")
    EnrollLocalLinkJob.perform_now
    handed_a_token

    revoked = []
    held = Resource::Machine::Enrollment.method(:revoke)
    Resource::Machine::Enrollment.define_singleton_method(:revoke) { |_tenant, client_id| revoked << client_id }
    @dir.join("client_id").write("second-client")
    EnrollLocalLinkJob.perform_now

    assert_equal [ "first-client" ], revoked
    Tenant.switch(@tenant) { assert_equal "second-client", Resource::Machine.local.client_id }
  ensure
    Resource::Machine::Enrollment.define_singleton_method(:revoke, held) if held
  end

  test "a client named with no token handed out, or long after one, is not taken and the card says why" do
    @dir.join("client_id").write("planted-client")
    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::Machine.local
      assert_nil local.client_id
      assert_match(/named the client planted-client, which no enrollment token xixo handed it/, local.check_error)
      local.update!(details: local.details.merge(Resource::Machine::MINTED => 1.hour.ago.utc.iso8601))
    end

    EnrollLocalLinkJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::Machine.local.client_id }
  end

  test "the card that said xixo link had not enrolled reads healthy once it binds and says hello" do
    Tenant.switch(@tenant) do
      local = Resource::Machine.local!
      local.probe
      assert_equal "local: xixo link beside the server has not enrolled yet", local.reload.check_error
    end

    handed_a_token
    @dir.join("client_id").write("local-client")
    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::Machine.local
      assert_nil local.check_error
      assert_nil local.checked_at

      local.greeted!({ "hostname" => "xixo" }, session: "one")
      assert local.reload.healthy?
    end
  end

  test "a check that read xixo link before it said hello is cleared by its next health report" do
    handed_a_token
    @dir.join("client_id").write("local-client")
    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::Machine.local
      local.greeted!({ "hostname" => "xixo" }, session: "one")
      local.update_columns(checked_at: Time.current, check_error: "local: xixo link has never connected")

      Resource::Machine.local.heard!({})
      assert local.reload.healthy?
    end
  end

  test "a client another machine is enrolled as is not taken" do
    Tenant.switch(@tenant) do
      Resource::Machine.create!(key: "box", details: { "host" => "100.64.0.9", "user" => "jon", "client_id" => "box-client" })
    end
    handed_a_token
    @dir.join("client_id").write("box-client")

    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::Machine.local
      assert_nil local.client_id
      assert_match(/which another machine is enrolled as/, local.check_error)
    end
  end

  test "binding the client the token made closes the wait, so a second name is not taken" do
    handed_a_token
    @dir.join("client_id").write("local-client")
    EnrollLocalLinkJob.perform_now
    @dir.join("client_id").write("later-client")
    EnrollLocalLinkJob.perform_now

    Tenant.switch(@tenant) { assert_equal "local-client", Resource::Machine.local.client_id }
  end

  test "a client id behind a link, or one that is not an id, is not taken" do
    handed_a_token
    secret = @root.join("secret").tap { |path| path.write("SECRET_KEY_BASE") }
    File.symlink(secret, @dir.join("client_id"))

    EnrollLocalLinkJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::Machine.local.client_id }

    File.unlink(@dir.join("client_id"))
    @dir.join("client_id").write("not an id; it has spaces")

    EnrollLocalLinkJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::Machine.local.client_id }
  end

  test "a tenant directory that is a link is passed over" do
    FileUtils.rm_rf(@dir)
    elsewhere = Pathname.new(Dir.mktmpdir).tap { |path| path.join("wanted").write("") }
    File.symlink(elsewhere, @dir)

    minting("misplaced") { EnrollLocalLinkJob.perform_now }

    assert_not elsewhere.join("token").exist?
  ensure
    FileUtils.rm_rf(elsewhere) if elsewhere
  end

  private

    def handed_a_token
      @dir.join("wanted").write("")
      FileUtils.rm_f(@dir.join("token"))
      minting("token-#{SecureRandom.hex(4)}") { EnrollLocalLinkJob.perform_now }
      FileUtils.rm_f(@dir.join("wanted"))
    end

    def minting(token)
      held = Resource::Machine::Enrollment.method(:mint)
      Resource::Machine::Enrollment.define_singleton_method(:mint) { |*, **| token }
      yield
    ensure
      Resource::Machine::Enrollment.define_singleton_method(:mint, held)
    end
end
