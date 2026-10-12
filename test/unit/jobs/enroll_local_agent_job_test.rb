require "test_helper"

class EnrollLocalAgentJobTest < ActiveSupport::TestCase
  setup do
    FakeAgent.standing = false
    @tenant = Tenant.create!(subdomain: "local-#{SecureRandom.hex(4)}", name: "Local")
    @root = Pathname.new(Dir.mktmpdir)
    @dir = @root.join(@tenant.subdomain).tap(&:mkpath)
    ENV["XIXO_LOCAL_AGENT"] = @root.to_s
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
    @dir.join("client_id").write("local-client\n")

    EnrollLocalAgentJob.perform_now

    Tenant.switch(@tenant) { assert_equal "local-client", Resource::XixoAgent.local.client_id }
  end

  test "an agent that enrolled again leaves its earlier client unenrolled in masks" do
    @dir.join("client_id").write("first-client")
    EnrollLocalAgentJob.perform_now

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

  test "a client id behind a link, or one that is not an id, is not taken" do
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

    def minting(token)
      held = Resource::XixoAgent::Enrollment.method(:mint)
      Resource::XixoAgent::Enrollment.define_singleton_method(:mint) { |*, **| token }
      yield
    ensure
      Resource::XixoAgent::Enrollment.define_singleton_method(:mint, held)
    end
end
