require "test_helper"
require_relative "../support/machines"

class LinkRolloutTest < ActiveSupport::TestCase
  include Machines

  SHIPPED = Resource::Machine::Downloads.version
  OLD = Digest::SHA256.hexdigest("old binary")

  setup do
    @tenant = Tenant.create!(subdomain: "rollout-#{SecureRandom.hex(4)}", name: "Rollout")
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-arm64"), "linux binary")
    File.binwrite(File.join(@binaries, "xixo-link-darwin-arm64"), "mac binary")
    files = [
      { "name" => "xixo-link-linux-arm64", "sha256" => Digest::SHA256.hexdigest("linux binary") },
      { "name" => "xixo-link-darwin-arm64", "sha256" => Digest::SHA256.hexdigest("mac binary") }
    ]
    File.write(File.join(@binaries, "release.json"), { "version" => SHIPPED, "serial" => 1234, "protocol" => 1, "files" => files }.to_json)
    File.write(File.join(@binaries, "release.sigstore.json"), "{}")
    ENV["XIXO_LINK_DIR"] = @binaries
    @state = Dir.mktmpdir
    @held = ENV.to_h.slice("XIXO_UPDATES_STATE")
    ENV["XIXO_UPDATES_STATE"] = @state

    @seasoned = linked("seasoned", "linux", updated: 3)
    @fresh = linked("fresh", "linux")
    @studio = linked("studio", "darwin")
    @paused = linked("paused", "linux")
    Tenant.switch(@tenant) { @paused.set_updates!(false) }
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    ENV["XIXO_UPDATES_STATE"] = @held["XIXO_UPDATES_STATE"]
    FileUtils.rm_rf(@binaries)
    FileUtils.rm_rf(@state)
  end

  test "no machine is offered the release before the server has been healthy for 15 minutes, then one per platform goes first" do
    rollout = tend!

    assert_equal "waiting_for_server", rollout.phase
    assert_equal [], offered

    travel 14.minutes
    assert_equal "waiting_for_server", tend!.phase

    travel 2.minutes
    rollout = tend!

    assert_equal "first", rollout.phase
    assert_equal({ "linux" => @seasoned.id, "darwin" => @studio.id }, rollout.first_machines.transform_values { |held| held["id"] })
    assert_equal [ @seasoned.key, @studio.key ], offered
    assert_equal "updating", switched { Resource::Machine.find(@seasoned.id).update_state }
    assert_equal "waiting", switched { Resource::Machine.find(@fresh.id).update_state }
  end

  test "everyone follows once each first machine has been on the release for 30 minutes" do
    tend!
    travel 16.minutes
    tend!
    arrived!(@seasoned, "linux binary")
    arrived!(@studio, "mac binary")

    rollout = tend!
    assert_equal "first", rollout.phase
    assert rollout.first_machines.values.all? { |held| held["arrived_at"] }

    travel 29.minutes
    assert_equal "first", tend!.phase

    travel 2.minutes
    rollout = tend!

    assert_equal "everyone", rollout.phase
    assert_includes offered, @fresh.key
    assert_not_includes offered, @paused.key
    assert switched { LinkRollout.allows?(Resource::Machine.find(@paused.id)) }

    arrived!(@fresh, "linux binary")
    assert_equal "done", tend!.phase
  end

  test "a rollback on a first machine holds the rollout, and the page sees why" do
    tend!
    travel 16.minutes
    tend!
    travel 1.minute
    switched do
      machine = Resource::Machine.find(@seasoned.id)
      machine.update!(details: machine.details.merge("rollback" => {
        "at" => Time.current.utc.iso8601, "version" => SHIPPED, "sha256" => Digest::SHA256.hexdigest("linux binary"), "error" => "it did not connect"
      }))
    end

    rollout = tend!

    assert_equal "held", rollout.phase
    assert_equal "seasoned went back to 0.0.1: it did not connect", rollout.held_reason
    assert_equal "held", switched { Resource::Machine.find(@fresh.id).update_state }
    assert_not switched { LinkRollout.allows?(Resource::Machine.find(@fresh.id)) }

    travel 1.minute
    switched { LinkRollout.request!("resume") }
    assert_equal "first", tend!.phase
  end

  test "a server that rolled back never starts the rollout, and a paused one waits" do
    rollout = tend!
    File.write(File.join(@state, "events.jsonl"), { at: 1.minute.from_now.utc.iso8601, action: "rollback", kind: "xixo" }.to_json + "\n")

    travel 16.minutes
    assert_equal [ "held", "the server rolled back" ], tend!.values_at(:phase, :held_reason)

    switched { rollout.reload.update!(phase: "waiting_for_server", held_reason: nil, started_at: Time.current) }
    switched { LinkRollout.request!("pause") }
    travel 16.minutes
    assert_equal "paused", tend!.phase

    switched { LinkRollout.request!("resume") }
    assert_equal "first", tend!.phase
  end

  test "an administrator picks the machine that goes first" do
    rollout = tend!
    switched { rollout.first!(Resource::Machine.find(@fresh.id)) }
    rollout = tend!

    assert_equal "first", rollout.phase
    assert_equal({ "id" => @fresh.id, "picked" => true }, rollout.first_machines["linux"])
    assert_equal [ @fresh.key ], offered

    error = assert_raises(LinkRollout::Refused) { switched { rollout.first!(Resource::Machine.find(@paused.id)) } }
    assert_match(/paused/, error.message)
  end

  private

    def linked(key, os, updated: 0)
      machine = machine_on(@tenant, key: key, client_id: "link-#{key}")
      switched do
        machine.update!(details: machine.details.merge(
          "updated" => { "count" => updated },
          "machine" => machine.machine.merge("os" => os, "arch" => "arm64", "version" => "0.0.1", "sha256" => OLD, "updates" => os == "darwin" ? "self" : "systemd")
        ))
      end
      machine
    end

    def arrived!(machine, body)
      switched do
        held = Resource::Machine.find(machine.id)
        held.update!(details: held.details.merge("machine" => held.machine.merge(
          "sha256" => Digest::SHA256.hexdigest(body), "version" => SHIPPED, "release" => LinkRollout.shipped["release"], "seen_at" => Time.current.utc.iso8601
        )))
      end
    end

    def tend!
      switched do
        Resource::Machine.find_each do |machine|
          machine.update_columns(details: machine.details.merge("machine" => machine.machine.merge("seen_at" => Time.current.utc.iso8601)))
        end
        LinkRollout.tend!
        LinkRollout.current
      end
    end

    def offered
      [ @seasoned, @fresh, @studio, @paused ].select do |machine|
        ActionCable.server.pubsub.broadcasts(LinkChannel.broadcasting_for(machine)).any? { |held| JSON.parse(held).key?("update") }
      end.map(&:key)
    end

    def switched(&)
      Tenant.switch(@tenant, &)
    end
end
