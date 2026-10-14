require "test_helper"
require_relative "../../support/machines"

class ExtractionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "extract-#{SecureRandom.hex(4)}", name: "Extraction")
    @machine = machine_on(@tenant, folders: [ "/srv/notes" ])

    Tenant.switch(@tenant) do
      @machine.update_columns(details: @machine.details.deep_merge("machine" => { "extractors" => %w[text] }))
      @folder = Resource::Filesystem.create!(key: "notes", name: "Notes", via: @machine, details: { "folder" => "/srv/notes" })
      @storage = Resource::Database.create!(key: "desk", name: "Desk")
    end
  end

  test "a file on a machine is read by that machine, where it lies" do
    feed = Tenant.switch(@tenant) { on_machine("plan.txt") }
    asked = []

    answering(asked, { "text" => "the plan" }) { analyze(feed) }

    assert_equal [ { "folder" => "/srv/notes", "path" => "plan.txt" } ],
                 asked.filter_map { |verb, args| args["source"] if verb == "extract" }
    assert_equal [ { "folder" => "/srv/notes", "path" => "plan.txt" } ], asked.filter_map { |verb, args| args if verb == "hash" }
    assert_not asked.any? { |verb, _| verb == "read" }
    assert_empty FakeLink.asked
    Tenant.switch(@tenant) do
      assert_equal "the plan", feed.reload.analysis.step_result("text")
      assert_equal sha("plan.txt"), feed.reference.digest
    end
  end

  test "a digest a machine has not reported yet is taken from its extraction" do
    feed = Tenant.switch(@tenant) { on_machine("later.txt") }
    asked = []

    with_method(Reference, :fingerprint!, -> { false }) do
      answering(asked, { "text" => "later" }) { analyze(feed) }
    end

    assert_not asked.any? { |verb, _| verb == "read" }
    Tenant.switch(@tenant) { assert_equal sha("later.txt"), feed.reference.reload.digest }
  end

  test "a file its machine cannot read, on a machine that lends none, stays there and waits for that machine" do
    feed = Tenant.switch(@tenant) { on_machine("budget.pdf") }
    asked = []

    assert_no_enqueued_jobs(only: AnalyzeFeedJob) do
      answering(asked, { "text" => "never" }) { analyze(feed) }
    end

    assert_not asked.any? { |verb, _| %w[read extract].include?(verb) }
    assert_empty FakeLink.asked
    Tenant.switch(@tenant) do
      analysis = feed.reload.analyses.last
      assert_equal "parked", analysis.status
      assert_equal "pdf", analysis.waits_for
      assert_equal @machine.id, analysis.waits_on_id
      assert_match(/box lacks the pdf extractor and lends none of its files/, analysis.step("extracted").dig("error", "message"))
      assert_equal "Waiting for box to be able to read PDFs, since it lends none of its files.", analysis.waiting
    end
  end

  test "a machine that lends sends a file it cannot read to a machine that reads for others" do
    lend!(@machine)
    feed = Tenant.switch(@tenant) { on_machine("budget.pdf") }
    asked = []

    with_method(Resource::Filesystem, :download, ->(_locator) { StringIO.new("%PDF bytes of the budget") }) do
      answering(asked, { "text" => "never" }) { analyze(feed) }
    end

    assert_not asked.any? { |verb, _| verb == "extract" }
    extracted = FakeLink.asked.select { |held| held.verb == "extract" }
    assert_equal 1, extracted.size
    assert_equal "%PDF bytes of the budget", extracted.first.bytes
    assert extracted.first.args.dig("source", "upload")
    Tenant.switch(@tenant) { assert_nil feed.reload.analysis.step("extracted").to_h["error"] }
  end

  test "the same file on two machines becomes one item by the digests the machines report" do
    other = machine_on(@tenant, key: "attic", folders: [ "/mnt/photos" ])
    first, second = Tenant.switch(@tenant) do
      copy = Resource::Filesystem.create!(key: "attic-photos", name: "Attic photos", via: other, details: { "folder" => "/mnt/photos" })
      [ on_machine("beach.jpg"), create_feed(resource: copy, locator_key: "beach-copy.jpg",
                                             locator: { "path" => "beach-copy.jpg", "size" => 10, "modified_at" => Time.current.utc.iso8601 }) ]
    end
    references = Tenant.switch(@tenant) { [ first, second ].map { |feed| feed.references.first.id } }
    asked = []

    answering(asked, {}, digests: { "beach.jpg" => sha("beach"), "beach-copy.jpg" => sha("beach") }) do
      Tenant.switch(@tenant) { DigestReferencesJob.perform_now }
    end

    assert_not asked.any? { |verb, _| verb == "read" }
    Tenant.switch(@tenant) do
      held = Reference.where(id: references).order(:id).to_a

      assert_equal [ sha("beach") ] * 2, held.map(&:digest)
      assert_equal 1, held.map(&:feed_id).uniq.size
    end
  end

  test "with no machine that reads for others connected, analysis is parked rather than tried again and again" do
    FakeLink.standing = false
    feed = Tenant.switch(@tenant) { stored("notes.txt", "remember the milk") }
    analysis = Tenant.switch(@tenant) { Analysis.open!(feed: feed, cause: "manual") }

    assert_no_enqueued_jobs(only: AnalyzeFeedJob) do
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, feed.id, analysis.id) }
    end

    Tenant.switch(@tenant) do
      analysis.reload
      assert analysis.parked?
      assert_nil analysis.waits_on_id
      assert_equal "text", analysis.waits_for
      assert_nil analysis.deadline
      assert_equal "Waiting for a machine that can read text.", analysis.waiting
      assert_match(/no connected machine that reads for others/, analysis.step("extracted").dig("error", "message"))
    end
  end

  test "a file no machine in the pool has the program for waits for one that does" do
    FakeLink.local.extractors = %w[text]
    feed = Tenant.switch(@tenant) { stored("plan.pdf", "%PDF") }

    analyze(feed)

    Tenant.switch(@tenant) do
      assert_equal [ "parked", "pdf" ], feed.reload.analyses.last.then { |held| [ held.status, held.waits_for ] }
    end
  end

  test "a machine whose file it is, offline, holds the file until it is back" do
    Tenant.switch(@tenant) { @machine.update_columns(details: @machine.details.deep_merge("machine" => { "connected" => false })) }
    feed = Tenant.switch(@tenant) { on_machine("plan.txt") }

    answering([], {}) { analyze(feed) }

    Tenant.switch(@tenant) do
      analysis = feed.reload.analyses.last
      assert analysis.parked?
      assert_equal @machine.id, analysis.waits_on_id
      assert_equal "Waiting for box, where it lives, to come back.", analysis.waiting
    end
  end

  test "an upload goes to the local machine first, while it has the program, and to the least busy one when it does not" do
    local = pooled(machine_on(@tenant, key: "local", folders: []), %w[text pdf])
    Tenant.switch(@tenant) { local.update_columns(details: local.details.merge("local" => true)) }
    attic = pooled(machine_on(@tenant, key: "attic", folders: []), %w[text pdf media])
    cellar = pooled(machine_on(@tenant, key: "cellar", folders: []), %w[text media])
    Tenant.switch(@tenant) do
      2.times { LinkExchange.create!(resource_id: attic.id, request: SecureRandom.uuid, verb: "extract") }
    end
    paper, song = Tenant.switch(@tenant) { [ stored("plan.pdf", "%PDF"), stored("song.mp3", "ID3") ] }
    asked = []

    staged = ->(io) { { "upload" => SecureRandom.uuid, "size" => io.read.to_s.bytesize } }
    with_method(Resource::Machine, :upload, staged) do
      with_method(Resource::Machine, :forget, ->(_request) { nil }) do
        answering(asked, { "text" => "read" }) do
          analyze(paper)
          analyze(song)
        end
      end
    end

    extracted = asked.filter_map { |verb, _args, key| key if verb == "extract" }
    assert_equal [ "local", "cellar" ], extracted
    assert_empty FakeLink.asked
  end

  test "a machine that does not read for others is left out of the pool" do
    FakeLink.standing = false
    attic = machine_on(@tenant, key: "attic", folders: [])
    Tenant.switch(@tenant) { attic.update_columns(details: attic.details.deep_merge("machine" => { "extractors" => %w[text], "extracts_for_others" => false })) }
    feed = Tenant.switch(@tenant) { stored("notes.txt", "milk") }

    analyze(feed)

    Tenant.switch(@tenant) { assert feed.reload.analyses.last.parked? }
  end

  test "a machine saying hello resumes the parked files it can read, and leaves the rest parked" do
    FakeLink.standing = false
    text, video = Tenant.switch(@tenant) { [ stored("notes.txt", "milk"), stored("clip.mp4", "ftyp") ] }
    analyze(text)
    analyze(video)
    attic = machine_on(@tenant, key: "attic", folders: [])

    Tenant.switch(@tenant) do
      assert_enqueued_with(job: ResumeParkedJob, args: [ attic.id ]) do
        attic.greeted!({ "folders" => [], "extractors" => %w[text pdf], "extracts_for_others" => true }, session: "s2")
      end

      assert_enqueued_with(job: AnalyzeFeedJob) { ResumeParkedJob.perform_now(attic.id) }
      assert_equal "queued", text.reload.analyses.last.status
      assert_equal "parked", video.reload.analyses.last.status
    end
  end

  test "parked files on a machine resume when it comes back, and the sweep finds what a hello missed" do
    Tenant.switch(@tenant) { @machine.update_columns(details: @machine.details.deep_merge("machine" => { "connected" => false })) }
    feed = Tenant.switch(@tenant) { on_machine("plan.txt") }
    answering([], {}) { analyze(feed) }
    Tenant.switch(@tenant) { @machine.update_columns(details: @machine.details.deep_merge("machine" => { "connected" => true })) }

    assert_enqueued_with(job: ResumeParkedJob) { SweepParkedJob.perform_now }
    Tenant.switch(@tenant) do
      ResumeParkedJob.perform_now
      assert_equal "queued", feed.reload.analyses.last.status
    end
  end

  test "files parked on a machine that was put away are let go to route again" do
    feed = Tenant.switch(@tenant) { on_machine("budget.pdf") }
    answering([], {}) { analyze(feed) }
    Tenant.switch(@tenant) do
      @machine.update_columns(archived_at: Time.current)

      ResumeParkedJob.perform_now
      assert_equal "queued", feed.reload.analyses.last.status
    end
  end

  test "analyzing a parked file again starts afresh" do
    FakeLink.standing = false
    feed = Tenant.switch(@tenant) { stored("notes.txt", "milk") }
    analyze(feed)

    Tenant.switch(@tenant) do
      parked = feed.reload.analyses.last
      feed.analyze!

      assert_equal "cancelled", parked.reload.status
    end
  end

  test "a text longer than the server reads is cut and says so, however long xixo link sent" do
    FakeLink.script = ->(*) { FakeLink.extracted({ "text" => "x" * (Analyzer::Base::MAX_TEXT + 10) }) }
    feed = Tenant.switch(@tenant) { stored("long.txt", "long") }

    analyze(feed)

    Tenant.switch(@tenant) do
      analysis = feed.reload.analysis

      assert_equal Analyzer::Base::MAX_TEXT, analysis.step_result("text").length
      assert_match(/only the first/, analysis.step_result("dropped")["text"])
    end
  end

  private

    def on_machine(name)
      create_feed(resource: @folder, locator_key: name, locator: { "path" => name, "size" => 10, "modified_at" => Time.current.utc.iso8601 })
    end

    def stored(name, body)
      @storage.upload(name, body)
      Feed.create!(type: Feed::FILE, key: name, title: name).tap do |feed|
        Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      end
    end

    def analyze(feed)
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, feed.id) }
    end

    def lend!(machine)
      Tenant.switch(@tenant) { machine.update_columns(details: machine.details.deep_merge("machine" => { "lend" => true })) }
    end

    def pooled(machine, extractors)
      Tenant.switch(@tenant) do
        machine.update_columns(details: machine.details.deep_merge("machine" => { "extractors" => extractors, "extracts_for_others" => true }))
        machine.reload
      end
    end

    def sha(name)
      Digest::SHA256.hexdigest("bytes of #{name}")
    end

    def answering(asked, steps, digests: {}, &)
      sha = method(:sha)
      exchanged = lambda do |verb, args = {}, within: nil, &block|
        asked << [ verb, args, key ]
        next block.call(FakeLink::Answer.new({ "size" => 0 }, {})) if verb == "read"

        if verb == "hash"
          found = digests.fetch(args["path"]) { sha.call(args["path"]) }
          next block.call(FakeLink::Answer.new({ "sha256" => found, "size" => 10 }, {}))
        end

        result, held = FakeLink.extracted(steps)
        path = args.dig("source", "path")
        result = result.deep_stringify_keys
        result = result.merge("sha256" => sha.call(path), "size" => 10) if path
        block.call(FakeLink::Answer.new(result, held))
      end

      with_method(Resource::Machine, :exchanged, exchanged, &)
    end

    def with_method(klass, name, body)
      original = klass.instance_method(name)
      original = original.super_method while original && original.owner != klass
      own = original.present?
      klass.define_method(name, &body)
      yield
    ensure
      own ? klass.define_method(name, original) : klass.remove_method(name)
    end
end
