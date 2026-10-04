require "test_helper"

class WalkTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "walk-#{SecureRandom.hex(4)}", name: "Walks")
    ENV["XIXO_GIT_ROOT"] = Dir.mktmpdir("walk-git")

    Tenant.switch(@tenant) do
      @git = Resource::Git.new(key: "repo", name: "Repo", details: { "url" => "https://example.test/r.git" })
      @git.save!(validate: false)
      @bucket = Resource::S3.create!(key: "bucket", details: { "endpoint" => FakeS3::ENDPOINT })
    end
  end

  teardown { ENV.delete("XIXO_GIT_ROOT") }

  test "a first walk, a stale one, and one of a type with no change feed walk everything" do
    Tenant.switch(@tenant) do
      assert Resource::Walk.begin!(@git).full?, "nothing to start from"

      @git.update_columns(sync_state: { "checkpoint" => { "commit" => "a" * 40 } }, walked_at: 2.days.ago)
      assert Resource::Walk.begin!(@git).full?, "the last full walk is more than a day old"

      @git.update_columns(walked_at: 1.hour.ago)
      assert_not Resource::Walk.begin!(@git).full?, "a fresh checkpoint walks only what changed"

      @bucket.update_columns(sync_state: { "checkpoint" => { "x" => 1 } }, walked_at: 1.hour.ago)
      assert Resource::Walk.begin!(@bucket).full?, "a bucket has no change feed to walk"
    end
  end

  test "what a walk reaches becomes the checkpoint only when it finishes, and a full one is remembered" do
    Tenant.switch(@tenant) do
      @git.update_columns(sync_state: { "checkpoint" => { "commit" => "old" } }, walked_at: nil)

      walk = Resource::Walk.begin!(@git)
      walk.reached({ "commit" => "new" })

      assert_equal({ "commit" => "old" }, @git.reload.sync_state["checkpoint"], "not yet")

      resumed = Resource::Walk.resume(@git.reload)
      resumed.reached({ "commit" => "newer" }, first: true)
      resumed.finish!(nil)

      assert_equal({ "commit" => "new" }, @git.reload.sync_state["checkpoint"], "the first commit reached is kept across a resume")
      assert_nil @git.sync_state["walk"]
      assert_in_delta Time.current, @git.walked_at, 5
    end
  end

  test "an abandoned walk leaves the checkpoint where the last finished one put it" do
    Tenant.switch(@tenant) do
      @git.update_columns(sync_state: { "checkpoint" => { "commit" => "old" } })

      Resource::Walk.begin!(@git).reached({ "commit" => "new" })
      Resource::Walk.new(@git.reload).abandon!

      assert_equal({ "checkpoint" => { "commit" => "old" } }, @git.reload.sync_state)
    end
  end

  test "a walk of only what changed never calls anything gone for not being seen" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "a.txt", title: "a.txt")
      reference = Reference.create!(feed: feed, resource: @git, locator_key: "a.txt", seen_at: 1.hour.ago)
      @git.update_columns(sync_state: { "checkpoint" => { "commit" => "old" } }, walked_at: 1.hour.ago)

      assert_equal 0, Resource::Walk.begin!(@git).finish!(1.minute.ago)
      assert_nil reference.reload.gone_at

      assert_equal 1, Resource::Walk.new(@git.reload).tap(&:start_over!).finish!(1.minute.ago)
      assert_predicate reference.reload.gone_at, :present?
    end
  end
end
