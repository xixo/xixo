require "test_helper"

class Resource
  class Unchecked < Resource
    def self.capabilities
      [ :compute ]
    end
  end
end

class ResourceCheckTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "check-#{SecureRandom.hex(4)}", name: "Checks")
    @bucket = "test-#{SecureRandom.hex(6)}"

    Tenant.switch(@tenant) do
      @reachable = Resource::S3.create!(key: @bucket, name: "Reachable",
                                        details: s3_details, credentials: s3_credentials)
      @unreachable = Resource::S3.create!(key: "gone", name: "Unreachable",
                                          details: { "endpoint" => "http://127.0.0.1:1" },
                                          credentials: s3_credentials)
      @storage = Resource::Database.create!(key: "database", name: "Storage")
    end

    @reachable.client.create_bucket(bucket: @bucket)
  end

  teardown do
    @reachable.client.delete_bucket(bucket: @bucket)
  rescue Aws::S3::Errors::NoSuchBucket
    nil
  end

  test "a resource that has never been checked is not healthy" do
    Tenant.switch(@tenant) do
      assert_nil @reachable.checked_at
      assert_not @reachable.healthy?
    end
  end

  test "checking a working resource records that it worked" do
    Tenant.switch(@tenant) do
      assert @reachable.check
      @reachable.reload

      assert_not_nil @reachable.checked_at
      assert_nil @reachable.check_error
      assert @reachable.healthy?
    end
  end

  test "a resource that cannot be reached answers false rather than raising" do
    Tenant.switch(@tenant) do
      assert_nothing_raised { assert_not @unreachable.check }
      @unreachable.reload

      assert_not_nil @unreachable.checked_at
      assert_match(/Resource::Failed/, @unreachable.check_error)
      assert_not @unreachable.healthy?
    end
  end

  test "a bucket the credentials cannot see is a failed check, not a missing one" do
    Tenant.switch(@tenant) do
      absent = Resource::S3.create!(key: "no-such-#{SecureRandom.hex(4)}", name: "Absent",
                                    details: s3_details, credentials: s3_credentials)

      assert_not absent.check
      assert_not_nil absent.reload.check_error
    end
  end

  test "a type with no check at all reports that rather than crashing the caller" do
    Tenant.switch(@tenant) do
      gpu = Resource::Unchecked.create!(key: "gpu-box", name: "GPU")

      assert_not gpu.check
      assert_match(/NotImplementedError/, gpu.reload.check_error)
    end
  end

  test "a passing check clears the error a failing one left" do
    Tenant.switch(@tenant) do
      @reachable.update_columns(checked_at: 1.day.ago, check_error: "Resource::Failed: earlier")

      assert @reachable.check
      assert_nil @reachable.reload.check_error
    end
  end

  test "the database resource checks without an endpoint or a credential" do
    Tenant.switch(@tenant) do
      assert @storage.check
      assert @storage.reload.healthy?
    end
  end

  private

    def s3_details
      {
        "endpoint" => ENV.fetch("S3_ENDPOINT", "http://127.0.0.1:9000"),
        "region" => ENV.fetch("S3_REGION", "us-east-1")
      }
    end

    def s3_credentials
      {
        "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
        "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "xixoxixo")
      }
    end
end
