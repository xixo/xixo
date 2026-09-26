require "test_helper"

module FailsToDiscover
  mattr_accessor :failing, default: false

  def discover!(**)
    raise "the disk went away" if FailsToDiscover.failing

    super
  end
end

Reference.singleton_class.prepend(FailsToDiscover)

class GatedIterationTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    ENV["URIS_FILESYSTEM_ROOTS"] = Dir.tmpdir

    @tenant = Tenant.create!(subdomain: "gated-#{SecureRandom.hex(4)}", name: "Gated")

    @root = Pathname.new(Dir.tmpdir) + @tenant.subdomain + "gated"
    @root.mkpath
    6.times { |index| (@root + "file-#{index}.txt").write("contents #{index}") }

    Tenant.switch(@tenant) do
      @resource = Resource::Filesystem.create!(
        key: "gated-#{SecureRandom.hex(4)}", details: { "root" => @root.to_s }
      )
    end
  end

  teardown do
    ENV.delete("URIS_FILESYSTEM_ROOTS")
    FileUtils.remove_entry(@root.dirname) if @root.dirname.exist?
  end

  test "an open gate catalogues everything, as before" do
    run = start_sync

    Tenant.switch(@tenant) do
      assert_equal 6, Feed.files.count
      assert_equal "done", run.reload.status
    end
  end

  test "a closed gate stops the run before it catalogues anything" do
    Tenant.switch(@tenant) { Gate.set!(key: "sync", enabled: false) }

    run = start_sync

    Tenant.switch(@tenant) do
      assert_equal 0, Feed.files.count
      assert_equal "gated", run.reload.status
    end
  end

  test "a gated-off sync releases the resource it had claimed" do
    Tenant.switch(@tenant) do
      Gate.set!(key: "sync", enabled: false)
      @resource.claim_sync!

      assert @resource.syncing?
    end

    start_sync

    Tenant.switch(@tenant) do
      assert_not @resource.reload.syncing?, "the gate stranded the resource lock"
      assert_nil @resource.sync_started_at
    end
  end

  teardown do
    FailsToDiscover.failing = false
  end

  test "a sync that fails lets go of the resource, without calling it synced" do
    Tenant.switch(@tenant) { @resource.update!(sync_interval: 1.hour.to_i) }
    Tenant.switch(@tenant) { @resource.claim_sync! }

    FailsToDiscover.failing = true
    assert_raises(RuntimeError) { start_sync }
    FailsToDiscover.failing = false

    Tenant.switch(@tenant) do
      @resource.reload

      assert_not @resource.syncing?, "a failed sync held the resource for six hours"
      assert_nil @resource.synced_at
      assert_in_delta 1.hour.from_now, @resource.next_sync_at, 5
    end
  end

  test "a gate on one resource leaves the others alone" do
    other = nil

    Tenant.switch(@tenant) do
      other = Resource::Filesystem.create!(
        key: "open-#{SecureRandom.hex(4)}", details: { "root" => @root.to_s }
      )
      Gate.set!(key: "sync", reference: @resource, enabled: false)
    end

    start_sync
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, other.id, nil) }
    Tenant.switch(@tenant) { assert_equal 6, Feed.files.count }
  end

  test "a dry run reports what it walked and catalogues none of it" do
    Tenant.switch(@tenant) { Gate.set!(key: "sync", enabled: true, live: false) }

    run = start_sync

    Tenant.switch(@tenant) do
      assert_equal 0, Feed.files.count
      assert_equal 6, run.reload.processed
      assert_equal "done", run.status
    end
  end

  test "the operator switch stops a run no tenant asked to stop" do
    ENV["URIS_ITERATORS_DISABLED"] = "1"

    begin
      run = start_sync

      Tenant.switch(@tenant) do
        assert_equal 0, Feed.files.count
        assert_equal "gated", run.reload.status
      end
    ensure
      ENV.delete("URIS_ITERATORS_DISABLED")
    end
  end

  private

    def start_sync
      run = Tenant.switch(@tenant) { Run.start!(kind: "sync", resource: @resource) }
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id, run.id) }
      run
    end
end
