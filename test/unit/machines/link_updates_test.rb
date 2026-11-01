require "test_helper"
require_relative "../../support/machines"

class LinkUpdatesTest < ActionCable::Channel::TestCase
  include Machines

  tests LinkChannel

  SHIPPED = Resource::Machine::Downloads.version
  OLD = Digest::SHA256.hexdigest("old binary")

  setup do
    @tenant = Tenant.create!(subdomain: "updates-#{SecureRandom.hex(4)}", name: "Updates")
    @machine = machine_on(@tenant, connected: false)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-arm64"), "linux binary")
    FileUtils.mkdir_p(File.join(@binaries, "mac"))
    File.binwrite(File.join(@binaries, "xixo-link-darwin-arm64"), "mac binary")
    File.binwrite(File.join(@binaries, "mac", "xixo-mac-reader"), "mac reader")
    ENV["XIXO_LINK_DIR"] = @binaries
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    FileUtils.rm_rf(@binaries)
  end

  test "xixo tells an out-of-date link to update to the build it ships, with that build's SHA-256" do
    assert_match(/\A\d+\.\d+\.\d+\z/, SHIPPED)

    told = greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ { "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary") } ],
                 told
    assert_equal OLD, fresh.machine["sha256"]
    assert_equal "systemd", fresh.machine["updates"]
    assert_equal false, fresh.current?
  end

  test "a Mac is told the mac reader's SHA-256 too, and is current only when both match" do
    told = greeted("os" => "darwin", "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("mac binary"), "updates" => "self")

    assert_equal [ Digest::SHA256.hexdigest("mac reader") ], told.map { |offer| offer["mac_reader"] }

    told = greeted("os" => "darwin", "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("mac binary"),
                   "mac_reader" => Digest::SHA256.hexdigest("mac reader"), "updates" => "self")

    assert_empty told
    assert fresh.current?
  end

  test "an image built from main names its commit after the release" do
    File.write(File.join(@binaries, "version"), "#{SHIPPED}+1a2b3c4\n")

    assert_equal "#{SHIPPED}+1a2b3c4", Resource::Machine::Downloads.version
    assert_equal "#{Resource::Machine::Downloads::RELEASES}/server-v#{SHIPPED}/xixo-mac-reader", Resource::Machine::Downloads.mac_reader

    told = greeted("version" => SHIPPED, "sha256" => OLD, "updates" => "systemd")

    assert_equal [ { "version" => "#{SHIPPED}+1a2b3c4", "sha256" => Digest::SHA256.hexdigest("linux binary") } ],
                 told
  end

  test "a version file that names no release is ignored" do
    File.write(File.join(@binaries, "version"), "main\n")

    assert_equal SHIPPED, Resource::Machine::Downloads.version
  end

  test "a link on the build xixo ships hears nothing" do
    assert_empty greeted("version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary"), "updates" => "systemd")
    assert fresh.current?
  end

  test "xixo cannot tell a link to go back: the offer names the build, and the link checks its signature and serial" do
    told = greeted("version" => "999.0.0", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ [ "sha256", "version" ] ], told.map { |offer| offer.keys.sort }
  end

  test "an image with a signed release names it in the offer, when the release lists the build offered" do
    listed = { "name" => "xixo-link-linux-arm64", "sha256" => Digest::SHA256.hexdigest("linux binary") }
    release = { "version" => SHIPPED, "serial" => 1234, "files" => [ listed ] }.to_json
    File.write(File.join(@binaries, "release.json"), release)
    File.write(File.join(@binaries, "release.sigstore.json"), "{}")
    everyone!

    told = greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ Digest::SHA256.hexdigest(release) ], told.map { |offer| offer["release"] }

    File.write(File.join(@binaries, "release.json"), { "version" => SHIPPED, "serial" => 1, "files" => [ listed.merge("sha256" => OLD) ] }.to_json)
    everyone!
    told = greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ nil ], told.map { |offer| offer["release"] }

    File.delete(File.join(@binaries, "release.sigstore.json"))
    told = greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ nil ], told.map { |offer| offer["release"] }
  end

  test "a link that cannot update itself, a paused one, and the one beside the server hear nothing" do
    assert_empty greeted("version" => "0.0.1", "sha256" => OLD)
    assert_empty greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "apt")
    assert_nil fresh.machine["updates"]

    Tenant.switch(@tenant) { fresh.set_updates!(false) }
    assert_empty greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    Tenant.switch(@tenant) { Resource::Machine.where(id: @machine.id).update_all(details: fresh.details.merge("updates" => true, "local" => true)) }
    assert_empty greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")
  end

  test "turning updates back on tells a connected link at once" do
    Tenant.switch(@tenant) { fresh.set_updates!(false) }
    greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")
    stream = LinkChannel.broadcasting_for(@machine)
    ActionCable.server.pubsub.clear_messages(stream)

    Tenant.switch(@tenant) { fresh.set_updates!(true) }

    told = ActionCable.server.pubsub.broadcasts(stream).map { |held| JSON.parse(held) }
    assert_equal [ SHIPPED ], told.filter_map { |held| held.dig("update", "version") }
  end

  test "a link from before updates names no build, so xixo cannot say it is current even at the same version" do
    assert_empty greeted("version" => SHIPPED)
    assert_nil fresh.current?
    assert_not fresh.updates_itself?
  end

  test "no build for the machine's system means no update, and the card cannot tell" do
    assert_empty greeted("arch" => "riscv64", "version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")
    assert_nil fresh.current?
  end

  test "a link's build and how it updates are kept only in their own shapes" do
    greeted("version" => "0.0.1", "sha256" => "ZZ#{OLD}", "mac_reader" => 5, "updates" => "systemd; rm -rf /")

    assert_nil fresh.machine["sha256"]
    assert_nil fresh.machine["mac_reader"]
    assert_nil fresh.machine["updates"]
  end

  test "with a signed release, a link hears nothing until the rollout reaches it, and the rollout starts waiting for the server" do
    release!

    assert_empty greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    rollout = Tenant.switch(@tenant) { LinkRollout.current! }
    assert_equal "waiting_for_server", rollout.phase
    assert_equal "waiting", fresh.update_state

    Tenant.switch(@tenant) { rollout.update!(phase: "everyone") }
    told = greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ rollout.release ], told.map { |offer| offer["release"] }
    assert_equal "updating", fresh.update_state
  end

  test "a link that speaks a newer protocol than xixo accepts is asked to go back to a release it holds within the window" do
    before = Digest::SHA256.hexdigest("before")
    held = [
      { "release" => Digest::SHA256.hexdigest("r1"), "sha256" => before, "version" => "0.3.0", "serial" => 5, "protocol" => 1 },
      { "release" => Digest::SHA256.hexdigest("r2"), "sha256" => OLD, "version" => "0.4.0", "serial" => 6, "protocol" => 2 },
      { "release" => Digest::SHA256.hexdigest("r0"), "sha256" => Digest::SHA256.hexdigest("older"), "version" => "0.2.0", "serial" => 4, "protocol" => 0 }
    ]

    assert_empty greeted("version" => "0.4.0", "sha256" => OLD, "updates" => "systemd", "protocol" => 2, "releases" => held)
    assert_equal [ { "version" => "0.3.0", "sha256" => before, "release" => Digest::SHA256.hexdigest("r1") } ], heard("roll_back")
    assert_equal "ahead", fresh.update_state
    assert_equal 2, fresh.protocol

    assert_empty greeted("version" => "0.4.0", "sha256" => OLD, "updates" => "systemd", "protocol" => 2, "releases" => [ held[1] ])
    assert_equal "waiting_for_xixo", fresh.update_state
  end

  test "a link reports what came of the last update, and xixo keeps the failure and counts the arrival" do
    failed = { "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary"), "ok" => false,
               "error" => "it did not connect", "at" => "2026-10-31T12:00:00Z" }

    greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd", "update_result" => failed)

    assert_equal failed.except("ok"), fresh.last_rollback
    assert_equal "updating", fresh.update_state
    Tenant.switch(@tenant) { assert_equal 1, AuditEvent.where(action: "link_update_failed").count }

    greeted("version" => "0.0.1", "sha256" => OLD, "updates" => "systemd", "update_result" => failed)
    Tenant.switch(@tenant) { assert_equal 1, AuditEvent.where(action: "link_update_failed").count }

    greeted("version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary"), "updates" => "systemd")

    assert_equal 1, fresh.updates_done
    assert_in_delta Time.current, fresh.last_updated_at, 5
    assert_nil fresh.details["offered"]
    assert_equal "current", fresh.update_state
    Tenant.switch(@tenant) { assert_equal 1, AuditEvent.where(action: "link_updated").count }
  end

  private

    def release!
      listed = { "name" => "xixo-link-linux-arm64", "sha256" => Digest::SHA256.hexdigest("linux binary"), "os" => "linux", "arch" => "arm64", "role" => "binary", "size" => 12 }
      File.write(File.join(@binaries, "release.json"), { "version" => SHIPPED, "serial" => 1234, "protocol" => 1, "files" => [ listed ] }.to_json)
      File.write(File.join(@binaries, "release.sigstore.json"), "{}")
    end

    def everyone!
      Tenant.switch(@tenant) { LinkRollout.current!.update!(phase: "everyone") }
    end

    def heard(kind)
      ActionCable.server.pubsub.broadcasts(LinkChannel.broadcasting_for(@machine)).filter_map { |held| JSON.parse(held)[kind] }
    end

    def greeted(said)
      stub_connection(tenant: @tenant, grant: nil, machine: @machine, client_id: @machine.client_id)
      subscribe
      stream = LinkChannel.broadcasting_for(@machine)
      ActionCable.server.pubsub.clear_messages(stream)

      perform :hello, { "os" => "linux", "arch" => "arm64", "hostname" => "box", "folders" => [ "/srv/media" ] }.merge(said)

      ActionCable.server.pubsub.broadcasts(stream).filter_map { |held| JSON.parse(held)["update"] }
    end

    def fresh
      Tenant.switch(@tenant) { Resource::Machine.find(@machine.id) }
    end
end
