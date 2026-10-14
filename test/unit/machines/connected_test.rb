require "test_helper"
require_relative "../../support/machines"

class ConnectedTest < ActiveSupport::TestCase
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "connected-#{SecureRandom.hex(4)}", name: "Connected")
    @machine = machine_on(@tenant, key: "media")
  end

  test "a machine loaded before a long job stays connected while xixo link keeps checking in" do
    Tenant.switch(@tenant) do
      held = Resource::Machine.find(@machine.id)

      travel 4.minutes
      Resource::Machine.find(@machine.id).heard!({})

      assert held.connected?
    end
  end

  test "a machine that stopped checking in is not connected, however recently it was loaded" do
    Tenant.switch(@tenant) do
      travel 4.minutes

      assert_not Resource::Machine.find(@machine.id).connected?
    end
  end

  test "a machine that parted is not connected, even with a fresh copy loaded before it left" do
    Tenant.switch(@tenant) do
      held = Resource::Machine.find(@machine.id)
      Resource::Machine.find(@machine.id).parted!(session: "s")

      travel 4.minutes

      assert_not held.connected?
    end
  end
end
