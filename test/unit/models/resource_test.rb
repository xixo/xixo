require "test_helper"

class ResourceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "res-#{SecureRandom.hex(4)}", name: "Resources")
  end

  test "a store xixo keeps for itself cannot be put away, synced, scheduled or made a default" do
    Tenant.switch(@tenant) do
      store = Resource.internal!(:children)

      assert_raises(ArgumentError) { store.sync! }
      assert_raises(ActiveRecord::RecordInvalid) { store.make_default_storage! }

      store.reload.assign_attributes(archived_at: Time.current, sync_interval: 1.hour.to_i)

      assert_not store.valid?
      assert_equal %i[archived_at sync_interval], store.errors.attribute_names.sort
    end
  end

  test "the stores xixo keeps for itself are not among the ones people attend to" do
    Tenant.switch(@tenant) do
      Resource.internal!(:derived)
      Resource.internal!(:children)

      Resource::S3.create!(key: "bucket", details: { "endpoint" => "http://x" })

      assert_equal [ "bucket" ], Resource.attended.pluck(:key)
    end
  end

  test "the stored type is the domain type, not the class name" do
    Tenant.switch(@tenant) do
      resource = Resource::S3.create!(key: "bucket", details: { "endpoint" => "http://x" })

      assert_equal "s3", resource.read_attribute(:type)
      assert_instance_of Resource::S3, Resource.find(resource.id)
    end
  end

  test "credentials are encrypted at rest" do
    Tenant.switch(@tenant) do
      resource = Resource::S3.create!(
        key: "bucket",
        details: { "endpoint" => "http://x" },
        credentials: { "access_key_id" => "AKIAsecret", "secret_access_key" => "shhh" }
      )

      stored = Resource.connection.select_value(
        "SELECT credentials FROM resources WHERE id = #{resource.id}"
      )

      assert_not_includes stored.to_s, "AKIAsecret"
      assert_not_includes stored.to_s, "shhh"
      assert_equal "AKIAsecret", resource.reload.credentials["access_key_id"]
    end
  end

  test "key is unique per tenant and type" do
    Tenant.switch(@tenant) do
      Resource::S3.create!(key: "bucket", details: { "endpoint" => "http://x" })

      duplicate = Resource::S3.new(key: "bucket", details: { "endpoint" => "http://x" })

      assert_not duplicate.valid?
    end
  end

  test "describe advertises capabilities and commands" do
    Tenant.switch(@tenant) do
      resource = Resource::S3.create!(key: "bucket", details: { "endpoint" => "http://x" })
      described = resource.describe

      assert_equal "s3", described[:type]
      assert_equal [ :storage ], described[:capabilities]
      assert_includes described[:commands].keys, :list
    end
  end
end
