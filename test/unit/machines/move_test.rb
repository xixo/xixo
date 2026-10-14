require "test_helper"
require_relative "../../support/machines"
require_relative "../../support/fake_links"

class MoveTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Machines

  self.use_transactional_tests = false

  BACKUP = "/Users/jon/Desktop-Backup".freeze
  DATA = "/srv/data/Desktop-Backup".freeze
  TAKEN_AT = Time.utc(2019, 7, 4, 12, 30)

  setup do
    SearchIndex.reset!
    @tenant = Tenant.create!(subdomain: "move-#{SecureRandom.hex(4)}", name: "Move")
    @mac = writing(machine_on(@tenant, key: "mac", folders: [ BACKUP ]), BACKUP)
    @media = writing(machine_on(@tenant, key: "media", folders: [ DATA ]), DATA)

    Tenant.switch(@tenant) do
      @backup = Resource::Filesystem.create!(key: "backup", details: { "folder" => BACKUP }, via: @mac)
      @data = Resource::Filesystem.create!(key: "data", details: { "folder" => DATA }, via: @media)
    end

    @raw = SecureRandom.random_bytes(700.kilobytes)
    @there = {
      "notes.txt" => FakeLinks::Held.new("a note".b, TAKEN_AT),
      "raws/2019/DSC_0001.NEF" => FakeLinks::Held.new(@raw.dup, TAKEN_AT),
      "raws/2019/DSC_0002.NEF" => FakeLinks::Held.new(SecureRandom.random_bytes(300), TAKEN_AT)
    }
    @here = {}
    @links = FakeLinks.new(@tenant, { @mac.id => { BACKUP => @there }, @media.id => { DATA => @here } }).start
    @grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "alice", "scope" => Grant::SIGN_IN.join(" ")))
  end

  teardown do
    @links&.stop
    Tenant.switch(@tenant) do
      [ Move, Reference, Analysis, Edge, Feed, Run, LinkExchange, AuditEvent, Resource ].each(&:delete_all)
    end
    @tenant.destroy!
  end

  test "a folder moves to another machine with its bytes and times, the originals go, and the catalog follows" do
    feed = Tenant.switch(@tenant) do
      @backup.keep!(Resource::Filesystem::Entry.new(path: "raws/2019/DSC_0001.NEF", size: @raw.bytesize, modified_at: TAKEN_AT)).feed
    end

    run = moving(path: "raws", into: "Archive")

    assert_equal "done", run.status, run.error
    assert_equal %w[Archive/raws/2019/DSC_0001.NEF Archive/raws/2019/DSC_0002.NEF], @here.keys.sort
    assert_equal @raw, @here["Archive/raws/2019/DSC_0001.NEF"].bytes
    assert_equal TAKEN_AT, @here["Archive/raws/2019/DSC_0001.NEF"].modified_at
    assert_equal %w[notes.txt], @there.keys

    Tenant.switch(@tenant) do
      moved = feed.reload.references.originals.sole
      assert_equal [ @data.id, "Archive/raws/2019/DSC_0001.NEF" ], [ moved.resource_id, moved.locator_key ]
      assert_equal Digest::SHA256.hexdigest(@raw), moved.digest

      progress = Move.progress(run.id)
      assert_equal [ 2, 2, 0, @raw.bytesize + 300, @raw.bytesize + 300 ],
                   [ progress.files, progress.files_done, progress.files_failed, progress.bytes, progress.bytes_done ]
      assert_equal 2, run.processed
      assert_equal 0, LinkExchange.count
      assert_equal 0, LinkChunk.count
    end
  end

  test "everything in a folder moves when no path is named, and none of it queues analysis" do
    run = moving

    assert_equal "done", run.status, run.error
    assert_equal @there.keys.sort, []
    assert_equal %w[notes.txt raws/2019/DSC_0001.NEF raws/2019/DSC_0002.NEF], @here.keys.sort
    Tenant.switch(@tenant) do
      assert_equal 0, Feed.count
      assert_equal 0, Analysis.count
    end
  end

  test "a move does not start from a folder its machine shares read-only, and names the folder to share writable" do
    Tenant.switch(@tenant) do
      held = Resource::Machine.find(@mac.id)
      held.update!(details: held.details.merge("machine" => held.machine.merge("writable" => [])))

      refused = assert_raises(Resource::Refused) do
        Move.start!(grant: @grant, destination: @data.reload, source: Resource::Filesystem.find(@backup.id))
      end

      assert_match(%r{mac shares /Users/jon/Desktop-Backup read-only}, refused.message)
      assert_match(%r{run the link-up command there again with /Users/jon/Desktop-Backup:rw among its folders}, refused.message)
      assert_equal 0, Run.count
    end
  end

  test "a folder shared writable takes a move with nothing set in xixo, and a config that leaves write out says so" do
    Tenant.switch(@tenant) do
      assert_equal @backup, Resource::Filesystem.find(@backup.id).movable!

      held = Resource::Machine.find(@mac.id)
      held.update!(details: held.details.merge("machine" => held.machine.merge("tools" => %w[browse search read extract])))

      refused = assert_raises(Resource::Refused) { Resource::Filesystem.find(@backup.id).movable! }
      assert_match(/xixo link's config on mac leaves write out of tools/, refused.message)
      assert_match(/Add write to tools in the config on mac/, refused.message)
    end
  end

  test "only an operator of both machines moves files" do
    stranger = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "mallory", "scope" => Grant::SIGN_IN.join(" ")))

    Tenant.switch(@tenant) do
      refused = assert_raises(Resource::Refused) { Move.start!(grant: stranger, destination: @data, source: @backup) }

      assert_match(/only an operator of media/, refused.message)
    end
  end

  test "a copy whose bytes do not match is removed, and the original stays" do
    @links.corrupting = true

    run = moving(path: "notes.txt")

    assert_equal "failed", run.status
    assert_match(/1 of 1 files stayed where they were/, run.error)
    assert_equal "a note", @there["notes.txt"].bytes
    assert_empty @here
    assert_match(/notes.txt stays on backup/, run.logs)
  end

  test "a different file already at the destination stays, and so does the original" do
    @here["notes.txt"] = FakeLinks::Held.new("another note".b, TAKEN_AT)

    run = moving(path: "notes.txt")

    assert_equal "failed", run.status
    assert_equal "another note", @here["notes.txt"].bytes
    assert_equal "a note", @there["notes.txt"].bytes
    assert_match(/data already holds another file at notes.txt/, run.logs)
  end

  test "a move started again finishes a file that was copied before it stopped, without copying it again" do
    @here["notes.txt"] = FakeLinks::Held.new("a note".b, TAKEN_AT)

    run = moving(path: "notes.txt")

    assert_equal "done", run.status, run.error
    assert_equal %w[raws/2019/DSC_0001.NEF raws/2019/DSC_0002.NEF], @there.keys.sort
    assert_equal "a note", @here["notes.txt"].bytes
    assert_not @links.verbs.any? { |_, verb, _| verb == "read" }
  end

  test "a selection of files moves into the folder by name" do
    feeds = Tenant.switch(@tenant) do
      %w[notes.txt raws/2019/DSC_0002.NEF].map do |path|
        @backup.keep!(Resource::Filesystem::Entry.new(path: path, size: @there[path].bytes.bytesize, modified_at: TAKEN_AT)).feed
      end
    end

    started = Tenant.switch(@tenant) { Move.start!(grant: @grant, destination: @data, into: "Inbox", feeds: { "id" => feeds.map(&:id) }) }
    performed
    run = Tenant.switch(@tenant) { started.reload }

    assert_equal "done", run.status, run.error
    assert_equal %w[Inbox/DSC_0002.NEF Inbox/notes.txt], @here.keys.sort
    assert_equal %w[raws/2019/DSC_0001.NEF], @there.keys
  end

  test "an agent moves a folder with the move tool, and checks on it by its run" do
    Current.grant = @grant
    started = Tenant.switch(@tenant) do
      JSON.parse(Tool::Move.call(server_context: {}, from: "backup", path: "notes.txt", to: "data").content.first[:text])
    end
    performed
    checked = Tenant.switch(@tenant) do
      JSON.parse(Tool::Move.call(server_context: {}, run: started["run"]).content.first[:text])
    end

    assert_equal "queued", started["status"]
    assert_equal "done", checked["status"]
    assert_equal({ "files" => 1, "files_done" => 1, "files_failed" => 0, "bytes" => 6, "bytes_done" => 6 }, checked["moved"])
    assert_equal %w[notes.txt], @here.keys
  ensure
    Current.grant = nil
  end

  test "a move between two folders on one machine is refused, since a file there can be its own copy" do
    Tenant.switch(@tenant) do
      again = Resource::Filesystem.create!(key: "backup-again", details: { "folder" => BACKUP }, via: @mac)

      refused = assert_raises(ArgumentError) do
        Move.start!(grant: @grant, destination: again, source: Resource::Filesystem.find(@backup.id))
      end

      assert_match(/both on mac/, refused.message)
      assert_equal 0, Run.count
    end

    assert_equal %w[notes.txt raws/2019/DSC_0001.NEF raws/2019/DSC_0002.NEF], @there.keys.sort
  end

  test "a move already planned between two folders on one machine removes nothing" do
    run = Tenant.switch(@tenant) do
      again = Resource::Filesystem.create!(key: "backup-again", details: { "folder" => BACKUP }, via: @mac)
      held = Run.start!(kind: "move", resource: again, selector: { "destination_id" => again.id, "into" => "",
                                                                    "source_id" => @backup.id, "root" => "" })
      PlanMoveJob.perform_later(@tenant.id, held.id)
      held
    end
    performed

    assert_equal %w[notes.txt raws/2019/DSC_0001.NEF raws/2019/DSC_0002.NEF], @there.keys.sort
    assert_not @links.verbs.any? { |_, verb, _| verb == "remove" }
    Tenant.switch(@tenant) { assert_equal "failed", run.reload.status }
  end

  test "a file that two machines reach on one disk is never its own copy" do
    beside = writing(machine_on(@tenant, key: "beside", folders: [ BACKUP ]), BACKUP)
    @links.add(beside.id, BACKUP, @there)
    besides = Tenant.switch(@tenant) { Resource::Filesystem.create!(key: "besides", details: { "folder" => BACKUP }, via: beside) }

    run = Tenant.switch(@tenant) do
      started = Move.start!(grant: @grant, destination: besides, source: Resource::Filesystem.find(@backup.id), path: "notes.txt")
      performed
      started.reload
    end

    assert_equal "failed", run.status
    assert_equal "a note", @there["notes.txt"]&.bytes
    assert_match(/notes.txt on besides is notes.txt on backup itself/, run.logs)
  end

  test "a copy stays when its original is gone before xixo removes it" do
    @links.removing = ->(folder, args) { folder.delete(args["path"]) }

    run = moving(path: "notes.txt")

    assert_equal "failed", run.status
    assert_equal "a note", @here["notes.txt"]&.bytes
    assert_match(/notes.txt is gone from backup/, run.logs)
  end

  test "a file another move is carrying stays where it is" do
    key = Tenant.switch(@tenant) { Move.carried_as(Resource::Machine.find(@mac.id), BACKUP, "notes.txt") }
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SELECT pg_advisory_lock(hashtextextended(#{connection.quote(key)}, 0))")
        held << true
        release.pop
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{connection.quote(key)}, 0))")
      end
    end
    held.pop

    run = moving(path: "notes.txt")
    release << true
    holder.join

    assert_equal "failed", run.status
    assert_equal "a note", @there["notes.txt"].bytes
    assert_empty @here
    assert_match(/another move is carrying notes.txt/, run.logs)
  end

  test "a copy keeps the fraction of a second in its modification time" do
    taken = Time.utc(2019, 7, 4, 12, 30, Rational(123_456, 1_000_000))
    @there["notes.txt"].modified_at = taken

    run = moving(path: "notes.txt")

    assert_equal "done", run.status, run.error
    assert_equal taken, @here["notes.txt"].modified_at
  end

  test "a selection moves only the files on machines its starter operated when it started" do
    elsewhere = "/srv/elsewhere"
    other = writing(machine_on(@tenant, key: "other", folders: [ elsewhere ], operators: [ "bob" ]), elsewhere)
    kept = {}
    feed = Tenant.switch(@tenant) do
      @backup.keep!(Resource::Filesystem::Entry.new(path: "notes.txt", size: 6, modified_at: TAKEN_AT)).feed
    end

    started = Tenant.switch(@tenant) { Move.start!(grant: @grant, destination: @data, into: "Inbox", feeds: { "id" => [ feed.id ] }) }

    Tenant.switch(@tenant) do
      folder = Resource::Filesystem.create!(key: "elsewhere", details: { "folder" => elsewhere }, via: other)
      kept["bob.txt"] = FakeLinks::Held.new("bob's".b, TAKEN_AT)
      folder.keep!(Resource::Filesystem::Entry.new(path: "bob.txt", size: 5, modified_at: TAKEN_AT)).update_columns(feed_id: feed.id)
    end
    @links.add(other.id, elsewhere, kept)
    performed

    Tenant.switch(@tenant) { assert_equal "done", started.reload.status, started.error }
    assert_equal({ "bob.txt" => "bob's" }, kept.transform_values(&:bytes))
    assert_equal %w[Inbox/notes.txt], @here.keys
  end

  test "a large file crosses part by part, and the server holds only a few parts at once" do
    Tenant.switch(@tenant) do
      Resource::Machine::Relay.new(
        from: Resource::Machine.find(@mac.id), folder: BACKUP, path: "raws/2019/DSC_0001.NEF", size: @raw.bytesize,
        to: Resource::Machine.find(@media.id), into: DATA, target: "copy.NEF", modified_at: TAKEN_AT, window: 300.kilobytes
      ).copy!
    end

    assert_equal @raw, @here["copy.NEF"].bytes
    reads = @links.verbs.select { |_, verb, _| verb == "read" }.map { |_, _, args| [ args["offset"], args["length"] ] }
    assert_equal [ [ 0, 300.kilobytes ], [ 300.kilobytes, 300.kilobytes ], [ 600.kilobytes, 100.kilobytes ] ], reads
    Tenant.switch(@tenant) { assert_equal 0, LinkChunk.count }
  end

  test "a relay that stops part way tells the machine taking the file to stop writing it" do
    media = Tenant.switch(@tenant) { Resource::Machine.find(@media.id) }

    assert_raises(Resource::Failed) do
      Tenant.switch(@tenant) do
        Resource::Machine::Relay.new(
          from: Resource::Machine.find(@mac.id), folder: BACKUP, path: "missing.NEF", size: 100,
          to: media, into: DATA, target: "copy.NEF"
        ).copy!
      end
    end

    cancels = ActionCable.server.pubsub.broadcasts(LinkChannel.broadcasting_for(media)).map { |raw| JSON.parse(raw) }
                                    .select { |message| message.key?("cancel") }
    assert_equal 1, cancels.size
    assert_empty @here
    Tenant.switch(@tenant) { assert_equal 0, LinkExchange.count }
  end

  test "a long transfer touches its exchanges well before the sweeper would take them" do
    assert_operator Resource::Machine::Relay::KEPT_ALIVE_EVERY * 10, :<, LinkExchange::KEPT_FOR
    assert_operator Resource::Machine::Relay::STALLS_AFTER, :<, LinkExchange::KEPT_FOR
  end

  private

    def writing(machine, folder)
      Tenant.switch(@tenant) do
        held = Resource::Machine.find(machine.id)
        held.update!(details: held.details.merge(
          "machine" => held.machine.merge("writable" => [ folder ], "tools" => Resource::Machine::Tools::NAMES, "lend" => true)
        ))
        held
      end
    end

    def moving(path: nil, into: nil)
      started = Tenant.switch(@tenant) do
        Move.start!(grant: @grant, destination: Resource::Filesystem.find(@data.id), into: into,
                    source: Resource::Filesystem.find(@backup.id), path: path)
      end
      performed

      Tenant.switch(@tenant) { started.reload }
    end

    def performed
      perform_enqueued_jobs until enqueued_jobs.empty?
    end
end
