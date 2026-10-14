require "test_helper"

class FolderChangesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "changes-#{SecureRandom.hex(4)}", name: "Changes")
    @root = Pathname.new(Dir.mktmpdir("changes"))
    @root.join("film.mkv").write("the film's bytes")
    @root.join("notes.txt").write("notes")

    Tenant.switch(@tenant) do
      @folder = disk_folder(@root, key: "films")
      walk
      DigestReferencesJob.perform_now
      Reference.where(resource_id: @folder.id).update_all(analyzed_at: 1.hour.ago)
      Analysis.update_all(status: "done", finished_at: 1.hour.ago)
      @film = Reference.find_by!(resource_id: @folder.id, locator_key: "film.mkv")
    end
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "a renamed file keeps its feed and its analysis, and takes its new name" do
    @root.join("film.mkv").rename(@root.join("Film (2002).mkv"))

    Tenant.switch(@tenant) do
      assert_no_difference -> { Analysis.count } do
        walk
      end

      held = Reference.originals.where(resource_id: @folder.id, gone_at: nil)
      assert_equal [ "Film (2002).mkv", "notes.txt" ], held.pluck(:locator_key).sort
      moved = held.find_by!(locator_key: "Film (2002).mkv")
      assert_equal @film.id, moved.id
      assert_equal @film.feed_id, moved.feed_id
      assert moved.analyzed_at
      assert_equal "Film (2002).mkv", moved.feed.title
    end
  end

  test "a rename xixo link tells of moves the reference without a walk" do
    @root.join("film.mkv").rename(@root.join("moved.mkv"))

    Tenant.switch(@tenant) do
      assert_no_difference -> { Analysis.count } do
        @folder.reload.looked_again!(%w[moved.mkv film.mkv])
      end

      assert_equal "moved.mkv", @film.reload.locator_key
      assert_nil @film.gone_at
      assert @film.analyzed_at
    end
  end

  test "a second name for the same file joins the same feed without a new analysis" do
    File.link(@root.join("film.mkv"), @root.join("again.mkv"))

    Tenant.switch(@tenant) do
      assert_no_difference -> { Analysis.count } do
        walk
      end

      again = Reference.find_by!(resource_id: @folder.id, locator_key: "again.mkv")
      assert_equal @film.feed_id, again.feed_id
      assert_equal @film.reload.digest, again.digest
      assert again.analyzed_at
      assert_equal "film.mkv", @film.locator_key
    end
  end

  test "a file touched but not changed is hashed again and keeps its analysis" do
    later = 1.day.from_now.to_time
    File.utime(later, later, @root.join("film.mkv"))
    File.utime(later, later, @root.join("notes.txt"))

    Tenant.switch(@tenant) do
      assert_no_difference -> { Analysis.count } do
        assert_enqueued_jobs 1, only: DigestReferencesJob do
          walk
        end
        @film.reload
        assert_nil @film.analyzed_at
        assert_nil @film.digest
        assert_predicate @film.prior_digest, :present?

        DigestReferencesJob.perform_now
      end

      @film.reload
      assert @film.analyzed_at
      assert_nil @film.prior_digest
      assert_equal Digest::SHA256.hexdigest("the film's bytes"), @film.digest
    end
  end

  test "a file whose bytes changed is analyzed again once its new hash is known" do
    @root.join("film.mkv").write("the director's cut")

    Tenant.switch(@tenant) do
      assert_no_difference -> { Analysis.count } do
        walk
      end

      assert_difference -> { Analysis.where(feed_id: @film.feed_id).count }, 1 do
        DigestReferencesJob.perform_now
      end

      @film.reload
      assert_nil @film.analyzed_at
      assert_nil @film.prior_digest
      assert_equal Digest::SHA256.hexdigest("the director's cut"), @film.digest
    end
  end

  test "a deleted file is gone after the next walk" do
    @root.join("notes.txt").delete

    Tenant.switch(@tenant) do
      walk

      assert Reference.find_by!(resource_id: @folder.id, locator_key: "notes.txt").gone_at
      assert_nil @film.reload.gone_at
    end
  end

  private

    def walk
      @folder.reload.claim_sync!
      SyncResourceJob.perform_now(@tenant.id, @folder.id)
    end
end
