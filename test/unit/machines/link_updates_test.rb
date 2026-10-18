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

    assert_equal [ { "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary"), "downgrade" => false } ],
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

  test "an image built from main names its commit after the release, and that is neither a downgrade nor the release" do
    File.write(File.join(@binaries, "version"), "#{SHIPPED}+1a2b3c4\n")

    assert_equal "#{SHIPPED}+1a2b3c4", Resource::Machine::Downloads.version
    assert_equal "#{Resource::Machine::Downloads::RELEASES}/server-v#{SHIPPED}/xixo-mac-reader", Resource::Machine::Downloads.mac_reader
    assert_not Resource::Machine::Downloads.older?("#{SHIPPED}+1a2b3c4", SHIPPED)
    assert_not Resource::Machine::Downloads.older?(SHIPPED, "#{SHIPPED}+1a2b3c4")
    assert Resource::Machine::Downloads.older?("#{SHIPPED}+1a2b3c4", "999.0.0")

    told = greeted("version" => SHIPPED, "sha256" => OLD, "updates" => "systemd")

    assert_equal [ { "version" => "#{SHIPPED}+1a2b3c4", "sha256" => Digest::SHA256.hexdigest("linux binary"), "downgrade" => false } ],
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

  test "a newer link is told to go back only with a downgrade xixo names" do
    told = greeted("version" => "999.0.0", "sha256" => OLD, "updates" => "systemd")

    assert_equal [ true ], told.map { |offer| offer["downgrade"] }
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

  private

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
