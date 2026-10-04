require "test_helper"

class RunTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "run-#{SecureRandom.hex(4)}", name: "Runs")
    @other = Tenant.create!(subdomain: "run-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "database", name: "Storage")
      60.times { |i| @storage.upload("note-#{i}.txt", "contents #{i}") }
    end
  end

  test "a run starts queued, becomes running, and finishes done" do
    run = Tenant.switch(@tenant) { @storage.sync! }

    assert_equal "queued", run.status
    assert_nil run.started_at

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id, run.id) }

    Tenant.switch(@tenant) do
      run.reload

      assert_equal "done", run.status
      assert_not_nil run.started_at
      assert_not_nil run.finished_at
      assert_equal 60, run.processed
    end
  end

  test "a cancelled run stops the iteration partway and stays cancelled" do
    run = Tenant.switch(@tenant) { @storage.sync! }
    Tenant.switch(@tenant) { run.cancel! }

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id, run.id) }

    Tenant.switch(@tenant) do
      run.reload

      assert_equal "cancelled", run.status
      assert_operator run.processed, :<, 60
    end
  end

  test "cancelling releases the sync lock, so the resource is not stuck" do
    run = Tenant.switch(@tenant) { @storage.sync! }

    Tenant.switch(@tenant) do
      assert @storage.reload.syncing?
      run.cancel!
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id, run.id) }

    Tenant.switch(@tenant) { assert_not @storage.reload.syncing? }
  end

  test "a deadline in the past cancels the run the first time it is checked" do
    run = Tenant.switch(@tenant) do
      @storage.sync!.tap { |r| r.update_columns(deadline: 1.minute.ago) }
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id, run.id) }

    Tenant.switch(@tenant) do
      run.reload

      assert_equal "cancelled", run.status
      assert_equal "deadline passed", run.error
    end
  end

  test "a run that never finishes cancelling is not resurrected by the job" do
    run = Tenant.switch(@tenant) { @storage.sync! }
    Tenant.switch(@tenant) { run.cancel! }

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id, run.id) }

    Tenant.switch(@tenant) do
      assert_equal "cancelled", run.reload.status
      assert_not_equal "done", run.status
    end
  end

  test "cancelling a finished run changes nothing" do
    Tenant.switch(@tenant) do
      run = Run.start!(kind: "sync", resource: @storage)
      run.finished!

      assert_not run.cancel!
      assert_equal "done", run.reload.status
    end
  end

  test "a run belongs to one tenant and is invisible to another" do
    run = Tenant.switch(@tenant) { Run.start!(kind: "sync", resource: @storage) }

    Tenant.switch(@other) { assert_nil Run.find_by(id: run.id) }
    Tenant.switch(@tenant) { assert_equal run, Run.find(run.id) }
  end

  test "an export records its own run" do
    Tenant.switch(@tenant) do
      run = Run.start!(kind: "export", resource: @storage, selector: { "kind" => "text" })

      assert_equal({ "kind" => "text" }, run.selector)
      assert run.open?
    end
  end

  test "a job with no run attached still works" do
    assert_nothing_raised { Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id) } }

    Tenant.switch(@tenant) { assert_equal 60, Feed.files.count }
  end

  test "a run announces how it settled, not only what it logged" do
    Tenant.switch(@tenant) do
      assert_equal [ :run_progressed ], announced { |run| run.finished! }
      assert_equal [ :run_progressed ], announced { |run| run.cancel! }
      assert_equal [ :run_progressed ], announced { |run| run.gated! }
    end
  end

  test "a run announces to the tenant and to whoever watches it by id" do
    Tenant.switch(@tenant) do
      heard = []
      run = Run.start!(kind: "sync", resource: @storage)
      subscriptions = XixoSchema.subscriptions

      subscriptions.define_singleton_method(:trigger) do |name, arguments = {}, *, **|
        heard << [ name, arguments ]
      end

      begin
        run.finished!
      ensure
        subscriptions.singleton_class.remove_method(:trigger)
      end

      assert_equal [ :run_progressed, :run_progressed ], heard.map(&:first)
      assert_includes heard.map(&:last), {}
      assert_includes heard.map(&:last), { id: run.id.to_s }
    end
  end

  test "a run that has already settled announces nothing further" do
    Tenant.switch(@tenant) do
      assert_empty announced { |run|
        run.cancel!
        run.finished!
      }.drop(1)
    end
  end

  private

    def announced(&block)
      topics(&block).map(&:first)
    end

    def topics
      heard = []
      run = Run.start!(kind: "sync", resource: @storage)
      subscriptions = XixoSchema.subscriptions

      subscriptions.define_singleton_method(:trigger) do |name, arguments = {}, *, **|
        heard << [ name, arguments ]
      end

      begin
        yield run
      ensure
        subscriptions.singleton_class.remove_method(:trigger)
      end

      heard.reject { |_name, arguments| arguments.present? }
    end
end
