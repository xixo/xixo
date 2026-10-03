require "test_helper"
require_relative "../../support/fake_model_server"

class Resource
  class Wire < Resource
    def self.capabilities
      [ :transport ]
    end

    def self.routable?
      true
    end

    def covers
      [ IPAddr.new("127.0.0.0/8") ]
    end

    def check!
      true
    end

    def reach!(target)
      target.sub("elsewhere.invalid", details.fetch("host"))
    end
  end
end

class ViaTest < ActiveSupport::TestCase
  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("gemma3:4b")

    @tenant = Tenant.create!(subdomain: "via-#{SecureRandom.hex(4)}", name: "Transports")
    @other = Tenant.create!(subdomain: "via-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @wire = Resource::Wire.create!(key: "tailnet", name: "The tailnet",
                                     details: { "host" => "127.0.0.1:#{@server.port}" })
    end
  end

  test "a resource reached directly has no via" do
    Tenant.switch(@tenant) { assert_nil @wire.via }
  end

  test "a transport declares the capability, and a storage resource does not" do
    Tenant.switch(@tenant) do
      assert @wire.transport?
      assert_not Resource::Database.create!(key: "disk").transport?
    end
  end

  test "something that is not a transport cannot be reached through" do
    Tenant.switch(@tenant) do
      disk = Resource::Database.create!(key: "disk")
      resource = Resource::OpenaiCompatible.new(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }, via: disk
      )

      assert_not resource.valid?
      assert_includes resource.errors[:via].join, "is not a transport"
    end
  end

  test "a resource cannot be reached through itself" do
    Tenant.switch(@tenant) do
      @wire.via_id = @wire.id

      assert_not @wire.valid?
      assert_includes @wire.errors[:via].join, "cannot be itself"
    end
  end

  test "a loop is refused" do
    Tenant.switch(@tenant) do
      second = Resource::Wire.create!(key: "second", details: { "host" => "x" }, via: @wire)
      @wire.via = second

      assert_not @wire.valid?
      assert_includes @wire.errors[:via].join, "would make a loop"
    end
  end

  test "a chain longer than MAX_HOPS is refused" do
    Tenant.switch(@tenant) do
      node = @wire

      Resource::MAX_HOPS.times do |index|
        node = Resource::Wire.create!(key: "hop-#{index}", details: { "host" => "x" }, via: node)
      end

      too_far = Resource::OpenaiCompatible.new(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }, via: node
      )

      assert_not too_far.valid?
      assert_includes too_far.errors[:via].join, "hops"
    end
  end

  test "another tenant's transport is refused by the validation" do
    elsewhere = Tenant.switch(@other) { Resource::Wire.create!(key: "theirs", details: { "host" => "x" }) }

    Tenant.switch(@tenant) do
      resource = Resource::OpenaiCompatible.new(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }
      )
      resource.via_id = elsewhere.id

      assert_not resource.valid?
      assert_includes resource.errors[:via].join, "another tenant"
    end
  end

  test "a via pointing at nothing this tenant can see is refused" do
    Tenant.switch(@tenant) do
      resource = Resource::OpenaiCompatible.new(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }
      )
      resource.via_id = 0

      assert_not resource.valid?
      assert_includes resource.errors[:via].join, "does not exist"
    end
  end

  test "the database refuses another tenant's transport even when the model is bypassed" do
    elsewhere = Tenant.switch(@other) { Resource::Wire.create!(key: "theirs", details: { "host" => "x" }) }

    Tenant.switch(@tenant) do
      brain = Resource::OpenaiCompatible.create!(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }
      )

      assert_raises(ActiveRecord::InvalidForeignKey) do
        Resource.transaction(requires_new: true) do
          Resource.where(id: brain.id).update_all(via_id: elsewhere.id)
        end
      end
    end
  end

  test "a new record that is already archived is not blamed for existing resources" do
    Tenant.switch(@tenant) do
      Resource::Database.create!(key: "one")
      Resource::Database.create!(key: "two")

      fresh = Resource::Database.new(key: "three", archived_at: Time.current)

      assert fresh.valid?, fresh.errors.full_messages.join(", ")
    end
  end

  test "a transport still in use cannot be archived" do
    Tenant.switch(@tenant) do
      brain = Resource::OpenaiCompatible.create!(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }, via: @wire
      )

      assert_not @wire.update(archived_at: Time.current)
      assert_includes @wire.errors[:archived_at].join, "brain"

      brain.update!(archived_at: Time.current)

      assert @wire.reload.update(archived_at: Time.current)
    end
  end

  test "the database refuses to delete a transport still in use" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "brain", details: { "base_url" => "http://elsewhere.invalid/v1" }, via: @wire
      )

      assert_raises(ActiveRecord::InvalidForeignKey) do
        Resource.transaction(requires_new: true) { Resource.where(id: @wire.id).delete_all }
      end
    end
  end

  test "an inference resource dials through its transport, with no allowlist needed" do
    ENV.delete("URIS_INFERENCE_ORIGINS")
    @server.answer_json({ summary: "reached" })

    Tenant.switch(@tenant) do
      brain = Resource::OpenaiCompatible.create!(
        key: "brain",
        details: { "base_url" => "http://elsewhere.invalid/v1", "models" => { "fast" => "gemma3:4b" } },
        via: @wire
      )

      assert_equal "reached", brain.summarize("hello", role: :fast)["summary"]
    end

    assert_equal 1, @server.count_for("/v1/chat/completions")
  end
end
