require "test_helper"

class SyncResourceJobTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "sync-#{SecureRandom.hex(4)}", name: "Sync")
    @other = Tenant.create!(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other")
    @bucket = "test-#{SecureRandom.hex(6)}"

    Tenant.switch(@tenant) do
      @resource = Resource::S3.create!(
        key: @bucket,
        name: "Test bucket",
        details: {
          "endpoint" => ENV.fetch("S3_ENDPOINT", "http://127.0.0.1:9000"),
          "region" => ENV.fetch("S3_REGION", "us-east-1")
        },
        credentials: {
          "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
          "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "urisuris")
        }
      )
    end

    @resource.client.create_bucket(bucket: @bucket)
    put "invoices/march.pdf"
    put "photos/beach.jpg"
    put "notes.txt"
  end

  teardown do
    objects = @resource.client.list_objects_v2(bucket: @bucket).contents
    objects.each { |o| @resource.client.delete_object(bucket: @bucket, key: o.key) }
    @resource.client.delete_bucket(bucket: @bucket)
  rescue Aws::S3::Errors::NoSuchBucket
    nil
  end

  test "syncing a bucket catalogues every object as a reference" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count

      pdf = feed_at("invoices/march.pdf")
      assert_equal "application/pdf", pdf.mime
      assert_equal "march.pdf", pdf.title
      assert_equal @bucket, pdf.locator["bucket"]
      assert_equal @resource, pdf.resource

      assert_equal "image/jpeg", feed_at("photos/beach.jpg").mime
      assert_equal "text/plain", feed_at("notes.txt").mime
    end
  end

  test "syncing twice converges rather than accumulating" do
    2.times { Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) } }

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
  end

  test "one object looked up by its key is the object a sync would have made" do
    Tenant.switch(@tenant) do
      synced = nil
      @resource.each_page { |batch, _| synced ||= batch.find { |object| object.key == "invoices/march.pdf" } }

      assert_kept_as_synced(@resource, synced, @resource.object_for("invoices/march.pdf"))
    end
  end

  test "a kept object is found again by the next sync rather than catalogued twice" do
    kept = Tenant.switch(@tenant) { @resource.command(:keep, key: "invoices/march.pdf") }

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal "application/pdf", kept["mime"]
      assert_equal "march.pdf", kept["title"]
      assert_equal [ "keep" ], feed_at("invoices/march.pdf").analyses.map(&:cause)
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count
      assert_equal kept["id"], feed_at("invoices/march.pdf").id.to_s
      assert_equal 1, feed_at("invoices/march.pdf").analyses.count, "a kept object still being analysed is not queued again"
    end
  end

  test "a kept object whose bytes move is noticed by the next sync like any other" do
    Tenant.switch(@tenant) do
      @resource.command(:keep, key: "notes.txt")
      reference_at("notes.txt").update!(analyzed_at: Time.current)
    end

    put "notes.txt", body: "remember the eggs too"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      notes = reference_at("notes.txt")

      assert notes.changed_at.present?
      assert_nil notes.analyzed_at
      assert_equal 2, feed_at("notes.txt").analyses.count
    end
  end

  test "keeping again after a sync changes nothing that did not change" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      @resource.command(:keep, key: "notes.txt")

      assert_nil reference_at("notes.txt").changed_at
      assert_equal 1, feed_at("notes.txt").analyses.count
    end
  end

  test "an object outside the bucket's prefix, or not there at all, is not kept" do
    Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "nothing/here.txt") }

      @resource.update!(details: @resource.details.merge("prefix" => "photos/"))

      assert_raises(ArgumentError) { @resource.command(:keep, key: "invoices/march.pdf") }
      assert_raises(ArgumentError) { @resource.command(:get, key: "invoices/march.pdf") }
      assert_raises(ArgumentError) { @resource.command(:list, prefix: "invoices/") }
      assert_raises(ArgumentError) { @resource.command(:put, key: "invoices/april.pdf", body: "x") }
      assert_equal 0, Feed.files.count
    end
  end

  test "an object deleted at the source is marked gone by the next sync, and found again if it comes back" do
    sync
    @resource.client.delete_object(bucket: @bucket, key: "photos/beach.jpg")

    travel 1.minute
    Tenant.switch(@tenant) { @resource.reload.claim_sync! }
    sync

    Tenant.switch(@tenant) do
      assert_predicate reference_at("photos/beach.jpg").gone_at, :present?
      assert_nil reference_at("notes.txt").gone_at
      assert_equal 3, Feed.files.count, "gone is noted, not deleted"
    end

    put "photos/beach.jpg"
    travel 1.minute
    Tenant.switch(@tenant) { @resource.reload.claim_sync! }
    sync

    Tenant.switch(@tenant) { assert_nil reference_at("photos/beach.jpg").gone_at }
  end

  test "an object kept by hand and never synced is not called gone by a sync that does not walk to it" do
    Tenant.switch(@tenant) do
      @resource.command(:keep, key: "notes.txt")
      @resource.update!(details: @resource.details.merge("prefix" => "photos/"))
      @resource.claim_sync!
    end

    sync

    Tenant.switch(@tenant) { assert_nil reference_at("notes.txt").gone_at }
  end

  test "a sync that only pretends, or was stopped, calls nothing gone" do
    sync
    @resource.client.delete_object(bucket: @bucket, key: "notes.txt")

    travel 1.minute
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: true, live: false)
      @resource.reload.claim_sync!
    end
    sync

    Tenant.switch(@tenant) { assert_nil reference_at("notes.txt").gone_at, "a dry run walks without keeping" }

    travel 1.minute
    run = Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: true, live: true)
      @resource.reload.claim_sync!
      Run.start!(kind: "sync", resource: @resource).tap(&:cancel!)
    end
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id, run.id) }

    Tenant.switch(@tenant) { assert_nil reference_at("notes.txt").gone_at }
  end

  test "a feed's window scrolling is not a deletion, so RSS never calls an entry gone" do
    assert_not Resource::Rss.notices_what_is_gone?
    assert Resource::S3.notices_what_is_gone?
  end

  test "a sync writes into one tenant only" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@other) { assert_equal 0, Feed.files.count }
  end

  test "the bytes are still in the resource, not in items" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      item = feed_at("notes.txt")

      assert_equal "contents of notes.txt", @resource.download(item.locator).read
    end
  end

  test "a first sync records the version the resource reports, and calls nothing changed" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      pdf = reference_at("invoices/march.pdf")

      assert pdf.version.present?
      assert_nil pdf.changed_at
    end
  end

  test "an object whose bytes moved is marked changed and queued for analysis again" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    was = Tenant.switch(@tenant) do
      reference_at("invoices/march.pdf").tap { |r| r.update!(analyzed_at: Time.current) }.version
    end

    put "invoices/march.pdf", body: "a corrected invoice"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      pdf = reference_at("invoices/march.pdf")

      assert_not_equal was, pdf.version
      assert pdf.changed_at.present?
      assert_nil pdf.analyzed_at, "a changed file has not been analyzed since it changed"
    end
  end

  test "an object that did not move is not marked changed, however often it is synced" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) { reference_at("notes.txt").update!(analyzed_at: Time.current) }

    2.times { Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) } }

    Tenant.switch(@tenant) do
      notes = reference_at("notes.txt")

      assert_nil notes.changed_at
      assert notes.analyzed_at.present?, "an unchanged file is not analyzed again"
    end
  end

  test "a file whose analysis has not finished is not queued again by the next sync" do
    3.times { Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) } }

    Tenant.switch(@tenant) do
      assert_equal 1, feed_at("notes.txt").analyses.count
    end
  end

  test "a file whose analysis failed waits for its bytes to change before it is queued again" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    Tenant.switch(@tenant) do
      feed_at("notes.txt").analyses.update_all(status: "failed", finished_at: Time.current)
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    Tenant.switch(@tenant) { assert_equal 1, feed_at("notes.txt").analyses.count }

    travel 1.second
    put "notes.txt", body: "remember the eggs too"
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    Tenant.switch(@tenant) { assert_equal 2, feed_at("notes.txt").analyses.count }
  end

  test "a failure is tried again once a day has passed, in case what failed was the model and not the file" do
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    Tenant.switch(@tenant) do
      feed_at("notes.txt").analyses.update_all(status: "failed", finished_at: Time.current)
    end

    travel Reference::RETRY_FAILED_AFTER + 1.minute
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    Tenant.switch(@tenant) { assert_equal 2, feed_at("notes.txt").analyses.count }
  end

  test "a sync that was cancelled lets the resource go without calling it synced" do
    run = Tenant.switch(@tenant) do
      @resource.update!(sync_interval: 1.hour.to_i)
      @resource.claim_sync!
      Run.start!(kind: "sync", resource: @resource).tap(&:cancel!)
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id, run.id) }

    Tenant.switch(@tenant) do
      @resource.reload

      assert_nil @resource.synced_at
      assert_nil @resource.sync_started_at, "a stopped sync does not hold the resource"
      assert @resource.next_sync_at.present?, "the schedule still comes round"
      assert_equal "cancelled", run.reload.status
    end
  end

  test "a sync its gate refused is not called synced" do
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: false)
      @resource.claim_sync!
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      @resource.reload

      assert_nil @resource.synced_at
      assert_nil @resource.sync_started_at
      assert_equal 0, Feed.files.count
    end
  end

  test "an object is saved with the cursor its page began at, so a resumed sync misses none of that page" do
    pages = { nil => [ %w[a b], "b" ], "b" => [ %w[c d], "d" ] }
    paged = Object.new
    paged.define_singleton_method(:each_page) do |cursor:, walk: nil, &block|
      while (page = pages[cursor])
        block.call(*page)
        cursor = page.last
      end
    end

    job = SyncResourceJob.new(@tenant.id, @resource.id)
    job.define_singleton_method(:resource_for) { |_id| paged }
    job.define_singleton_method(:walk_for) { |_resource, _cursor| nil }

    walked = job.build_enumerator(@tenant.id, @resource.id, cursor: nil).to_a

    assert_equal [ [ "a", nil ], [ "b", "b" ], [ "c", "b" ], [ "d", "d" ] ], walked

    stopped_after = walked.index { |object, _| object == "c" }
    resumed = job.build_enumerator(@tenant.id, @resource.id, cursor: walked[stopped_after].last).to_a

    assert_equal %w[c d], resumed.map(&:first)
  end

  test "a resource that cannot report a version never claims anything changed" do
    versionless = Tenant.switch(@tenant) do
      Resource::Imap.new(key: "mail", details: {}, credentials: {})
    end

    assert_nil versionless.version_for(versionless.locator_for(
      Struct.new(:mailbox, :uidvalidity, :uid).new("INBOX", 1, 2)
    ))
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    def put(key, body: nil)
      @resource.client.put_object(bucket: @bucket, key: key, body: body || "contents of #{key}")
    end

    def reference_at(locator_key)
      Reference.find_by!(resource_id: @resource.id, locator_key: locator_key)
    end
end
