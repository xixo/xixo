require "test_helper"

class GateTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "gate-#{SecureRandom.hex(4)}", name: "Gates")
    @other = Tenant.create!(subdomain: "gate-#{SecureRandom.hex(4)}", name: "Other")
  end

  test "an iterator nobody has configured behaves the way it declared" do
    Tenant.switch(@tenant) do
      assert Gate.decide(key: "sync").enabled
      assert_not Gate.decide(key: "prune", enabled: false).enabled
    end
  end

  test "a key-wide gate closes every reference under it" do
    Tenant.switch(@tenant) do
      resource = scratch_resource
      Gate.set!(key: "sync", enabled: false)

      assert_not Gate.decide(key: "sync").enabled
      assert_not Gate.decide(key: "sync", reference: resource).enabled
    end
  end

  test "a gate on the reference beats the key-wide one" do
    Tenant.switch(@tenant) do
      resource = scratch_resource
      Gate.set!(key: "sync", enabled: false)
      Gate.set!(key: "sync", reference: resource, enabled: true)

      assert Gate.decide(key: "sync", reference: resource).enabled
      assert_not Gate.decide(key: "sync").enabled
    end
  end

  test "enabled but not live is a dry run" do
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: true, live: false)
      decision = Gate.decide(key: "sync")

      assert decision.enabled
      assert decision.dry_run?
      assert_not decision.closed?
    end
  end

  test "one tenant's gate does not reach another's iterators" do
    Tenant.switch(@tenant) { Gate.set!(key: "sync", enabled: false) }

    Tenant.switch(@other) { assert Gate.decide(key: "sync").enabled }
  end

  test "two key-wide gates for one key cannot both exist" do
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: false)

      assert_raises(ActiveRecord::RecordNotUnique) do
        Gate.transaction(requires_new: true) do
          Gate.insert!({ tenant_id: @tenant.id, key: "sync", enabled: true, live: true,
                         created_at: Time.current, updated_at: Time.current })
        end
      end
    end
  end

  test "a reference needs both halves or neither" do
    Tenant.switch(@tenant) do
      assert_not Gate.new(key: "sync", reference_type: "Resource").valid?
      assert Gate.new(key: "sync").valid?
    end
  end

  test "the operator switch closes everything regardless of rows" do
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: true, live: true)

      ENV["URIS_ITERATORS_DISABLED"] = "1"
      begin
        assert Gate.decide(key: "sync").closed?
      ensure
        ENV.delete("URIS_ITERATORS_DISABLED")
      end
    end
  end
end
