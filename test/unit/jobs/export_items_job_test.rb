require "test_helper"

class Resource
  class Compute < Resource
    def self.capabilities
      [ :compute ]
    end
  end
end

class ExportItemsJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "exp-#{SecureRandom.hex(4)}", name: "Export")
    @source_bucket = "src-#{SecureRandom.hex(6)}"
    @destination_bucket = "dst-#{SecureRandom.hex(6)}"

    Tenant.switch(@tenant) do
      @source = build_resource(@source_bucket, "Source")
      @destination = build_resource(@destination_bucket, "Backup")
    end

    @source.client.create_bucket(bucket: @source_bucket)
    @destination.client.create_bucket(bucket: @destination_bucket)

    put @source, "invoices/march.pdf"
    put @source, "photos/beach.jpg"

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @source.id) }
    SearchIndex.refresh!
  end

  teardown do
    [ [ @source, @source_bucket ], [ @destination, @destination_bucket ] ].each do |resource, bucket|
      resource.client.list_objects_v2(bucket: bucket).contents.each do |object|
        resource.client.delete_object(bucket: bucket, key: object.key)
      end
      resource.client.delete_bucket(bucket: bucket)
    rescue Aws::S3::Errors::NoSuchBucket
      nil
    end
  end

  test "everything in the catalog reaches the destination resource" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    assert_equal [
      "#{@source_bucket}/invoices/march.pdf",
      "#{@source_bucket}/photos/beach.jpg"
    ].sort, exported_keys
  end

  test "the bytes arrive intact" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    body = @destination.client.get_object(
      bucket: @destination_bucket, key: "#{@source_bucket}/invoices/march.pdf"
    ).body.read

    assert_equal "contents of invoices/march.pdf", body
  end

  test "a selector narrows what is exported" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, { "mime" => "image/jpeg" }) }

    assert_equal [ "#{@source_bucket}/photos/beach.jpg" ], exported_keys
  end

  test "a search query is a selector too" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, { "query" => "march" }) }

    assert_equal [ "#{@source_bucket}/invoices/march.pdf" ], exported_keys
  end

  test "a destination without the storage capability is refused" do
    compute = Tenant.switch(@tenant) { Resource::Compute.create!(key: "gpu-box", name: "GPU") }

    error = assert_raises(ArgumentError) do
      Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, compute.id, {}) }
    end

    assert_match(/is not storage/, error.message)
    assert_empty exported_keys
  end

  test "an item already referenced on the destination is not exported into it" do
    put @destination, "invoices/march.pdf"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @destination.id) }
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      copy = feed_at(@destination, "invoices/march.pdf")
      copy.references.each { |reference| reference.move_to!(feed_at(@source, "invoices/march.pdf")) }
    end

    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    assert_equal [
      "invoices/march.pdf",
      "#{@source_bucket}/photos/beach.jpg"
    ].sort, exported_keys
  end

  test "the copy is catalogued as another reference to the same item" do
    assert_no_difference -> { Tenant.switch(@tenant) { Feed.files.count } } do
      assert_difference -> { Tenant.switch(@tenant) { Reference.count } }, 2 do
        Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }
      end
    end

    Tenant.switch(@tenant) do
      item = feed_at(@source, "invoices/march.pdf")
      copy = item.references.find_by(resource_id: @destination.id)

      assert_equal "#{@source_bucket}/invoices/march.pdf", copy.locator_key
      assert_equal "contents of invoices/march.pdf", copy.download.read
    end
  end

  test "an item already exported is not exported again" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }
    put @destination, "#{@source_bucket}/invoices/march.pdf", body: "written by someone else"
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    body = @destination.client.get_object(
      bucket: @destination_bucket, key: "#{@source_bucket}/invoices/march.pdf"
    ).body.read

    assert_equal "written by someone else", body
  end

  test "syncing the destination afterwards discovers nothing new" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    assert_no_difference [ -> { Tenant.switch(@tenant) { Feed.files.count } },
                           -> { Tenant.switch(@tenant) { Reference.count } } ] do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @destination.id) }
    end
  end

  test "the copy records the version of the bytes it was made from" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    Tenant.switch(@tenant) do
      item = feed_at(@source, "invoices/march.pdf")
      source = item.source_for(@destination)
      copy = item.copy_at(@destination)

      assert copy.source_version.present?
      assert_equal source.version, copy.source_version
      assert_not copy.stale_against?(source)
    end
  end

  test "a source that changed is exported again, over the copy that is now wrong" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    put @source, "invoices/march.pdf", body: "a corrected invoice"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @source.id) }

    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    body = @destination.client.get_object(
      bucket: @destination_bucket, key: "#{@source_bucket}/invoices/march.pdf"
    ).body.read

    assert_equal "a corrected invoice", body
  end

  test "re-exporting overwrites the copy rather than leaving two" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    put @source, "invoices/march.pdf", body: "a corrected invoice"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @source.id) }

    assert_no_difference -> { Tenant.switch(@tenant) { Reference.count } } do
      Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }
    end

    assert_equal [
      "#{@source_bucket}/invoices/march.pdf",
      "#{@source_bucket}/photos/beach.jpg"
    ].sort, exported_keys
  end

  test "a re-export leaves the copy matching its source again, so a third does nothing" do
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    put @source, "invoices/march.pdf", body: "a corrected invoice"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @source.id) }
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    put @destination, "#{@source_bucket}/invoices/march.pdf", body: "written by someone else"
    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    body = @destination.client.get_object(
      bucket: @destination_bucket, key: "#{@source_bucket}/invoices/march.pdf"
    ).body.read

    assert_equal "written by someone else", body,
                 "a copy is rewritten because its source moved, not because it differs"
  end

  test "a copy nobody exported is left alone, because nothing knows what it holds" do
    put @destination, "invoices/march.pdf"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @destination.id) }

    Tenant.switch(@tenant) do
      copy = feed_at(@destination, "invoices/march.pdf")
      copy.references.each { |reference| reference.move_to!(feed_at(@source, "invoices/march.pdf")) }
    end

    put @source, "invoices/march.pdf", body: "a corrected invoice"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @source.id) }

    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    body = @destination.client.get_object(
      bucket: @destination_bucket, key: "invoices/march.pdf"
    ).body.read

    assert_equal "contents of invoices/march.pdf", body
  end

  test "a copy landing where another item already lives takes that reference over" do
    put @destination, "#{@source_bucket}/invoices/march.pdf"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @destination.id) }

    squatter = Tenant.switch(@tenant) { feed_at(@destination, "#{@source_bucket}/invoices/march.pdf") }

    Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, @destination.id, {}) }

    Tenant.switch(@tenant) do
      assert_nil Feed.find_by(id: squatter.id)
      assert_equal feed_at(@source, "invoices/march.pdf").id,
                   Reference.find_by(resource_id: @destination.id,
                                     locator_key: "#{@source_bucket}/invoices/march.pdf").feed_id
    end
  end

  private

    def build_resource(bucket, name)
      Resource::S3.create!(
        key: bucket,
        name: name,
        details: {
          "endpoint" => ENV.fetch("S3_ENDPOINT", "http://127.0.0.1:9000"),
          "region" => ENV.fetch("S3_REGION", "us-east-1")
        },
        credentials: {
          "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
          "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "xixoxixo")
        }
      )
    end

    def put(resource, key, body: nil)
      resource.client.put_object(bucket: resource.bucket, key: key, body: body || "contents of #{key}")
    end

    def feed_at(resource, locator_key)
      Feed.joins(:references)
           .find_by(feed_references: { resource_id: resource.id, locator_key: locator_key })
    end

    def exported_keys
      @destination.client.list_objects_v2(bucket: @destination_bucket).contents.map(&:key).sort
    end
end
