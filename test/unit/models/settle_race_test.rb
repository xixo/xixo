require "test_helper"

class SettleRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  WAIT = 2

  module Gate
    mattr_accessor :barrier

    def absorb!(...)
      Gate.barrier&.wait(WAIT)
      super
    end
  end

  Feed.prepend(Gate)

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "race-#{SecureRandom.hex(4)}", name: "Race")

    Tenant.switch(@tenant) do
      drop = Resource::Database.create!(key: "drop", name: "Drop")
      shelf = Resource::Database.create!(key: "shelf", name: "Shelf")

      @references = [ placed(drop, "report.pdf"), placed(shelf, "copy of report.pdf") ]
    end
  end

  teardown do
    Gate.barrier = nil

    Tenant.switch(@tenant) do
      [ AuditEvent, Edge, Analysis, Reference, ResourceBlob, Feed, Resource ].each(&:delete_all)
    end

    @tenant.delete
  end

  test "two settles of the same twins at once join them once" do
    Gate.barrier = Concurrent::CyclicBarrier.new(2)
    failures = Queue.new

    racers = @references.map do |reference|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Tenant.switch(@tenant) { Reference.find(reference.id).settle! }
        end
      rescue StandardError => e
        failures << e
      end
    end

    racers.each(&:join)

    assert failures.empty?, -> { failures.size.times.map { failures.pop }.map { |e| "#{e.class}: #{e.message}" }.join("\n") }

    Tenant.switch(@tenant) do
      survivor = Feed.files.sole

      assert_equal @references.map(&:id).sort, survivor.references.originals.pluck(:id).sort
      assert_equal 1, AuditEvent.where(action: "join_feeds").count
    end
  end

  private

    def placed(resource, key)
      resource.upload(key, "the same bytes")
      feed = Feed.create!(type: Feed::FILE, key: key, title: key)
      reference = Reference.record!(feed: feed, resource: resource, locator_key: key, locator: { "key" => key })
      reference.update_columns(digest: Fingerprint.of("the same bytes"))
      reference
    end
end
