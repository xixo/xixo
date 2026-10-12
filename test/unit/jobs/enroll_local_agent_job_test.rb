require "test_helper"

class EnrollLocalAgentJobTest < ActiveSupport::TestCase
  setup do
    FakeAgent.standing = false
    @tenant = Tenant.create!(subdomain: "local-#{SecureRandom.hex(4)}", name: "Local")
    connect!(@tenant)
    @root = Pathname.new(Dir.mktmpdir)
    @dir = @root.join(@tenant.subdomain).tap(&:mkpath)
    ENV["XIXO_LOCAL_AGENT"] = @root.to_s
  end

  test "a tenant not yet connected to masks is passed over without minting" do
    @tenant.disconnect!
    @dir.join("wanted").write("")

    EnrollLocalAgentJob.perform_now

    assert_not @dir.join("token").exist?
  end

  teardown do
    ENV.delete("XIXO_LOCAL_AGENT")
    FileUtils.rm_rf(@root)
  end

  test "an agent that wants enrolling is left a token only it can read" do
    @dir.join("wanted").write("")

    minting("first-token") { EnrollLocalAgentJob.perform_now }

    token = @dir.join("token")
    assert_equal "first-token", token.read
    assert_equal "600", format("%o", token.stat.mode & 0o777)
    Tenant.switch(@tenant) { assert Resource::XixoAgent.local&.local? }
  end

  test "a fresh token is not replaced, and a stale one is" do
    @dir.join("wanted").write("")
    @dir.join("token").write("held")

    minting("second-token") { EnrollLocalAgentJob.perform_now }
    assert_equal "held", @dir.join("token").read

    File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, @dir.join("token"))
    minting("second-token") { EnrollLocalAgentJob.perform_now }
    assert_equal "second-token", @dir.join("token").read
  end

  test "an agent that wants nothing is left nothing" do
    minting("unasked") { EnrollLocalAgentJob.perform_now }

    assert_not @dir.join("token").exist?
  end

  test "the client the agent enrolled as becomes the agent beside the server" do
    handed_a_token
    @dir.join("client_id").write("local-client\n")

    EnrollLocalAgentJob.perform_now

    Tenant.switch(@tenant) { assert_equal "local-client", Resource::XixoAgent.local.client_id }
  end

  test "an agent that enrolled again leaves its earlier client unenrolled in masks" do
    handed_a_token
    @dir.join("client_id").write("first-client")
    EnrollLocalAgentJob.perform_now
    handed_a_token

    revoked = []
    held = Resource::XixoAgent::Enrollment.method(:revoke)
    Resource::XixoAgent::Enrollment.define_singleton_method(:revoke) { |_tenant, client_id| revoked << client_id }
    @dir.join("client_id").write("second-client")
    EnrollLocalAgentJob.perform_now

    assert_equal [ "first-client" ], revoked
    Tenant.switch(@tenant) { assert_equal "second-client", Resource::XixoAgent.local.client_id }
  ensure
    Resource::XixoAgent::Enrollment.define_singleton_method(:revoke, held) if held
  end

  test "a client named with no token handed out, or long after one, is not taken and the card says why" do
    @dir.join("client_id").write("planted-client")
    EnrollLocalAgentJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::XixoAgent.local
      assert_nil local.client_id
      assert_match(/named the client planted-client, which no enrollment token xixo handed it/, local.check_error)
      local.update!(details: local.details.merge(Resource::XixoAgent::MINTED => 1.hour.ago.utc.iso8601))
    end

    EnrollLocalAgentJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::XixoAgent.local.client_id }
  end

  test "a client another machine is enrolled as is not taken" do
    Tenant.switch(@tenant) do
      Resource::XixoAgent.create!(key: "box", details: { "host" => "100.64.0.9", "user" => "jon", "client_id" => "box-client" })
    end
    handed_a_token
    @dir.join("client_id").write("box-client")

    EnrollLocalAgentJob.perform_now

    Tenant.switch(@tenant) do
      local = Resource::XixoAgent.local
      assert_nil local.client_id
      assert_match(/which another machine is enrolled as/, local.check_error)
    end
  end

  test "binding the client the token made closes the wait, so a second name is not taken" do
    handed_a_token
    @dir.join("client_id").write("local-client")
    EnrollLocalAgentJob.perform_now
    @dir.join("client_id").write("later-client")
    EnrollLocalAgentJob.perform_now

    Tenant.switch(@tenant) { assert_equal "local-client", Resource::XixoAgent.local.client_id }
  end

  test "a client id behind a link, or one that is not an id, is not taken" do
    handed_a_token
    secret = @root.join("secret").tap { |path| path.write("SECRET_KEY_BASE") }
    File.symlink(secret, @dir.join("client_id"))

    EnrollLocalAgentJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::XixoAgent.local.client_id }

    File.unlink(@dir.join("client_id"))
    @dir.join("client_id").write("not an id; it has spaces")

    EnrollLocalAgentJob.perform_now
    Tenant.switch(@tenant) { assert_nil Resource::XixoAgent.local.client_id }
  end

  test "a tenant directory that is a link is passed over" do
    FileUtils.rm_rf(@dir)
    elsewhere = Pathname.new(Dir.mktmpdir).tap { |path| path.join("wanted").write("") }
    File.symlink(elsewhere, @dir)

    minting("misplaced") { EnrollLocalAgentJob.perform_now }

    assert_not elsewhere.join("token").exist?
  ensure
    FileUtils.rm_rf(elsewhere) if elsewhere
  end

  private

    def handed_a_token
      @dir.join("wanted").write("")
      FileUtils.rm_f(@dir.join("token"))
      minting("token-#{SecureRandom.hex(4)}") { EnrollLocalAgentJob.perform_now }
      FileUtils.rm_f(@dir.join("wanted"))
    end

    def minting(token)
      held = Resource::XixoAgent::Enrollment.method(:mint)
      Resource::XixoAgent::Enrollment.define_singleton_method(:mint) { |*, **| token }
      yield
    ensure
      Resource::XixoAgent::Enrollment.define_singleton_method(:mint, held)
    end
end
