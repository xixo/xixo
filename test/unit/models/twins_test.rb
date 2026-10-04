require "test_helper"

class TwinsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "twin-#{SecureRandom.hex(4)}", name: "Twins")

    Tenant.switch(@tenant) do
      @drop = Resource::Database.create!(key: "drop", name: "Drop")
      @shelf = Resource::Database.create!(key: "shelf", name: "Shelf")
      @mine = Resource::Database.create!(key: "mine", name: "Mine", owner_subject: "someone")
    end
  end

  test "the same bytes in two resources become one feed with two places" do
    Tenant.switch(@tenant) do
      held(@drop, "report.pdf", "the same bytes")
      held(@shelf, "copy of report.pdf", "the same bytes")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      survivor = Feed.files.sole

      assert_equal "report.pdf", survivor.title
      assert_equal %w[drop shelf], survivor.references.originals.map { |held| held.resource.key }.sort
      assert_equal [ "join_feeds" ], AuditEvent.where(feed: survivor).pluck(:action)
    end
  end

  test "a personal copy joins only the same person's places" do
    Tenant.switch(@tenant) do
      held(@drop, "a.txt", "shared bytes")
      held(@shelf, "b.txt", "shared bytes")
      held(@mine, "c.txt", "shared bytes")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      assert_equal 2, Feed.files.count
      assert_equal [ "mine" ], feed_at("c.txt").references.map { |held| held.resource.key }
    end
  end

  test "empty files stay apart" do
    Tenant.switch(@tenant) do
      held(@drop, "a.log", "")
      held(@shelf, "b.log", "")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) { assert_equal 2, Feed.files.count }
  end

  test "a file taken out of an archive stays with its archive" do
    Tenant.switch(@tenant) do
      children = Resource.internal!(:children)
      archive = held(@drop, "bundle.zip", "zip bytes")
      held(@shelf, "inner.txt", "inner bytes")
      child = Feed.create!(type: Feed::FILE, key: "inner.txt", title: "inner.txt", parent: archive)
      children.upload("#{archive.id}/0/0/inner.txt", "inner bytes")
      Reference.record!(feed: child, resource: children, locator_key: "#{archive.id}/0/0/inner.txt",
                        locator: { "key" => "#{archive.id}/0/0/inner.txt" })
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
  end

  test "the absorbed feed's connections, note, and lifetime join the survivor" do
    Tenant.switch(@tenant) do
      older = held(@drop, "a.txt", "same")
      newer = held(@shelf, "b.txt", "same")
      older.connect!(Feed.tag!("kept"))
      newer.connect!(Feed.tag!("taxes"))
      newer.connect!(older)
      older.update!(note: "from the drop", expires_at: 2.days.from_now)
      newer.update!(note: "from the shelf")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      survivor = Feed.files.sole

      assert_equal %w[kept taxes], survivor.tags.map(&:key).sort
      assert_equal "from the drop\n\nfrom the shelf", survivor.note
      assert_nil survivor.expires_at, "a feed that lasts forever outlasts any date"
    end
  end

  test "joining reindexes the survivor without embedding it again" do
    Tenant.switch(@tenant) do
      older = held(@drop, "a.txt", "same")
      newer = held(@shelf, "b.txt", "same")
      older.update_columns(embedded_at: 1.hour.ago)
      @older = older.id
      @newer = newer.id
    end

    DigestReferencesJob.perform_now
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      assert_not_nil Feed.find(@older).embedded_at
      assert_includes SearchIndex.search("a.txt"), @older
      assert_not_includes SearchIndex.search("b.txt"), @newer
    end
  end

  test "a feed still being analyzed is joined by its own analysis" do
    Tenant.switch(@tenant) do
      held(@drop, "a.txt", "same")
      newer = held(@shelf, "b.txt", "same")
      Analysis.open!(feed: newer, cause: "sync")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) { assert_equal 2, Feed.files.count }
  end

  test "a place kept apart stays apart until its bytes change" do
    Tenant.switch(@tenant) do
      held(@drop, "a.txt", "same")
      apart = held(@shelf, "b.txt", "same")
      apart.references.sole.update!(kept_apart: true)
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      assert_equal 2, Feed.files.count

      apart = feed_at("b.txt").references.sole
      apart.update_columns(version: "first")
      apart.note_version!("edited")
      assert_not apart.kept_apart
    end
  end

  test "a join never reaches another tenant" do
    other = Tenant.create!(subdomain: "twin-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) { held(@drop, "a.txt", "same") }
    Tenant.switch(other) do
      held(Resource::Database.create!(key: "drop", name: "Drop"), "a.txt", "same")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) { assert_equal 1, Feed.files.count }
    Tenant.switch(other) { assert_equal 1, Feed.files.count }
  end

  test "a copy synced later joins before its analysis reads anything" do
    Tenant.switch(@tenant) do
      held(@drop, "a.txt", "same").analyze!(cause: "sync")
    end
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      newer = held(@shelf, "b.txt", "same")
      newer.analyze!(cause: "sync")
    end

    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      assert_equal %w[a.txt b.txt], Feed.files.sole.references.originals.map(&:locator_key).sort
      assert_nil Reference.find_by!(locator_key: "b.txt").analyzed_at, "the twin was never read"
    end
  end

  test "splitting a place off by hand keeps it apart" do
    Tenant.switch(@tenant) do
      older = held(@drop, "a.txt", "same")
      older.connect!(Feed.tag!("kept"))
      held(@shelf, "b.txt", "same")
    end

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      reference = Reference.find_by!(locator_key: "b.txt")
      reference.split!.update!(kept_apart: true)

      assert_equal [ "kept" ], reference.feed.tags.map(&:key)
      assert_equal reference.feed, reference.settle!
      assert_equal 2, Feed.files.count
    end
  end

  test "an edited copy leaves with every connection and the note, and a touched one comes back" do
    synced_twice do |_left, right|
      Tenant.switch(@tenant) do
        joined = Feed.files.sole
        joined.connect!(Feed.tag!("taxes"))
        joined.update!(note: "for the accountant")
      end

      (right + "report.txt").write("edited bytes")
      File.utime(1.day.from_now.to_time, 1.day.from_now.to_time, right + "report.txt")
      sync_and_analyze(@two)

      Tenant.switch(@tenant) do
        assert_equal 2, Feed.files.count

        edited = Feed.referencing(@two.id).sole
        assert_not_equal Feed.referencing(@one.id).sole, edited
        assert_equal [ "taxes" ], edited.tags.map(&:key)
        assert_equal "for the accountant", edited.note
      end

      (right + "report.txt").write("the same bytes")
      File.utime(2.days.from_now.to_time, 2.days.from_now.to_time, right + "report.txt")
      sync_and_analyze(@two)

      Tenant.switch(@tenant) { assert_equal 1, Feed.files.count }
    end
  end

  private

    def held(resource, key, body)
      resource.upload(key, body)
      feed = Feed.create!(type: Feed::FILE, key: key, title: key)
      Reference.record!(feed: feed, resource: resource, locator_key: key, locator: { "key" => key })
      feed
    end
    def synced_twice
      allowed = Pathname.new(Dir.mktmpdir("permitted"))
      left = (allowed + @tenant.subdomain + "left").tap(&:mkpath)
      right = (allowed + @tenant.subdomain + "right").tap(&:mkpath)
      (left + "report.txt").write("the same bytes")
      (right + "report.txt").write("the same bytes")
      ENV["XIXO_FILESYSTEM_ROOTS"] = allowed.to_s

      Tenant.switch(@tenant) do
        @one = Resource::Filesystem.create!(key: "left", name: "Left", details: { "root" => left.to_s })
        @two = Resource::Filesystem.create!(key: "right", name: "Right", details: { "root" => right.to_s })
      end

      sync_and_analyze(@one)
      sync_and_analyze(@two)

      Tenant.switch(@tenant) { assert_equal 1, Feed.files.count }

      yield left, right
    ensure
      ENV.delete("XIXO_FILESYSTEM_ROOTS")
      FileUtils.remove_entry(allowed) if allowed&.exist?
    end

    def sync_and_analyze(resource)
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, resource.id) }
      perform_enqueued_jobs(only: AnalyzeFeedJob)
    end
end
