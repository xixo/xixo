require "test_helper"
require_relative "../../support/machines"
require_relative "../../support/fake_model_server"

class ModelWaitingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Machines

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b")
    ENV["XIXO_INFERENCE_ORIGINS"] = "#{@server.origin},http://127.0.0.1:#{closed_port}"

    @tenant = Tenant.create!(subdomain: "waits-#{SecureRandom.hex(4)}", name: "Waits")
    @machine = machine_on(@tenant, key: "laptop")

    Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge(
        "tools" => %w[browse search read models],
        "services" => [ { "kind" => "ollama", "port" => 11434, "address" => "100.64.0.9" } ]
      )))
      storage = Resource::Database.create!(key: "drop", name: "Drop")
      storage.upload("notes.txt", "remember the milk")
      @feed = Feed.create!(type: Feed::FILE, key: "notes.txt", title: "notes.txt")
      Reference.record!(feed: @feed, resource: storage, locator_key: "notes.txt", locator: { "key" => "notes.txt" })
    end
  end

  teardown { ENV.delete("XIXO_INFERENCE_ORIGINS") }

  test "a summary whose model server sits on a machine that is asleep waits for it, and keeps what it read" do
    on_laptop
    asleep!

    analysis = analyze

    Tenant.switch(@tenant) do
      analysis.reload
      assert_equal "parked", analysis.status
      assert_equal [ Analyzer::MODELS, @machine.id ], [ analysis.waits_for, analysis.waits_on_id ]
      assert_nil analysis.deadline
      assert_nil analysis.started_at
      assert_nil analysis.error
      assert_equal "remember the milk", analysis.step_result("text")
      assert_equal "Waiting for laptop to come online.", analysis.waiting
      assert_equal "Waiting for laptop to come online.", Types::FeedType.allocate.tap { |held| held.instance_variable_set(:@object, @feed.reload) }.unsummarized
    end
  end

  test "a machine that wakes and says hello puts its waiting summaries back in the queue" do
    on_laptop
    asleep!
    analysis = analyze

    Tenant.switch(@tenant) do
      assert_enqueued_with(job: ResumeParkedJob, args: [ @machine.id ]) do
        @machine.reload.greeted!({ "folders" => [ "/srv/media" ], "tools" => %w[browse search read models],
                                   "services" => [ { "kind" => "ollama", "port" => 11434, "address" => "100.64.0.9" } ] },
                                 session: "s2")
      end

      assert_enqueued_with(job: AnalyzeFeedJob) { ResumeParkedJob.perform_now(@machine.id) }
      assert_equal "queued", analysis.reload.status
      assert_not_nil analysis.deadline
    end
  end

  test "the sweep resumes summaries waiting on a machine that is online, and leaves the asleep one waiting" do
    on_laptop
    asleep!
    analysis = analyze

    Tenant.switch(@tenant) do
      ResumeParkedJob.perform_now
      assert_equal "parked", analysis.reload.status

      awake!
      ResumeParkedJob.perform_now
      assert_equal "queued", analysis.reload.status
    end
  end

  test "a resumed summary is written once the model answers" do
    on_laptop
    asleep!
    analysis = analyze
    Tenant.switch(@tenant) { awake! }
    @replies = [ chat_reply({ summary: "A note about milk.", entities: [], tags: [ "groceries" ] }) ]

    Tenant.switch(@tenant) do
      ResumeParkedJob.perform_now(@machine.id)
      relaying { perform_enqueued_jobs(only: AnalyzeFeedJob) }
      analysis.reload

      assert_equal "done", analysis.status
      assert_equal "A note about milk.", analysis.summary
    end
  end

  test "a model server that refuses the connection is tried again, then waits, then gives up after many tries" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "direct", name: "Direct", details: { "base_url" => "http://127.0.0.1:#{closed_port}/v1", "models" => { "default" => "qwen3:8b" } }
      ).tap(&:make_default_inference!)
    end

    analysis = Tenant.switch(@tenant) { @feed.analyze!(cause: "manual") }
    Tenant.switch(@tenant) do
      drained
      analysis.reload

      assert_equal "parked", analysis.status
      assert_equal "Waiting for Direct to answer.", analysis.waiting
      assert_equal 3, analysis.turns.size

      (AnalyzeFeedJob::MOST_UNANSWERED - 1).times { analysis.log_skip("parked", AnalyzeFeedJob::UNANSWERED, "earlier") }
      analysis.unparked!
      AnalyzeFeedJob.enqueue(@feed, analysis)
      drained

      assert_equal "failed", analysis.reload.status
      assert_match(/xixo stopped waiting after #{AnalyzeFeedJob::MOST_UNANSWERED} tries/, analysis.error)
    end
  end

  test "a model the server does not have still fails, and says so" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "default" => "qwen3:8b" } }
      ).tap(&:make_default_inference!)
    end
    @server.refuse(404, body: { error: "model 'qwen3:8b' not found" }.to_json)

    analysis = analyze

    Tenant.switch(@tenant) do
      assert_equal "failed", analysis.reload.status
      assert_match(/The summary failed\. ollama: 127\.0\.0\.1 answered 404/, analysis.error)
    end
  end

  test "a link that says the model server is not running waits on its machine" do
    on_laptop
    @refusal = "laptop: xixo link said this machine runs no model server of that kind: dial tcp 127.0.0.1:11434: connection refused"

    analysis = Tenant.switch(@tenant) { @feed.analyze!(cause: "manual") }
    Tenant.switch(@tenant) do
      relaying { drained }
      analysis.reload

      assert_equal [ "parked", @machine.id ], [ analysis.status, analysis.waits_on_id ]
      assert_equal "Waiting for the model server on laptop to answer.", analysis.waiting
    end
  end

  test "reading a file grants the run as long as a machine may take to answer" do
    analysis = Tenant.switch(@tenant) { Analysis.open!(feed: @feed, cause: "sync") }

    Tenant.switch(@tenant) do
      analysis.running!
      assert_operator analysis.deadline, :<, 20.minutes.from_now

      analysis.allow!(Extraction::WITHIN)
      assert_in_delta Extraction::WITHIN.from_now, analysis.reload.deadline, 5

      analysis.allow!(1.minute)
      assert_in_delta Extraction::WITHIN.from_now, analysis.reload.deadline, 5
    end
  end

  test "a file waiting for a summary is not opened again by the sweep for unsummarized files" do
    on_laptop
    asleep!
    analyze

    Tenant.switch(@tenant) { assert_not_includes Feed.unsummarized, @feed }
  end

  test "failed and expired analyses go back to wait for the model server, each file once, with what they had read" do
    on_laptop
    other, asked, fine = Tenant.switch(@tenant) do
      [ Feed.create!(type: Feed::FILE, key: "film.srt", title: "film.srt"),
        Feed.create!(type: Feed::FILE, key: "question", title: "question"),
        Feed.create!(type: Feed::FILE, key: "done.txt", title: "done.txt") ]
    end

    Tenant.switch(@tenant) do
      Analysis.create!(feed: @feed, cause: "sync", status: "failed", error: "The summary failed. laptop is offline",
                       steps: { "text" => { "result" => "remember the milk" } })
      Analysis.create!(feed: other, cause: "sync", status: "done")
      Analysis.create!(feed: other, cause: "sync", status: "cancelled", error: Analysis::EXPIRED)
      Analysis.create!(feed: asked, cause: "ask", status: "failed", error: "no")
      Analysis.create!(feed: fine, cause: "sync", status: "failed", error: "old")
      Analysis.create!(feed: fine, cause: "manual", status: "done")

      assert_enqueued_with(job: ResumeParkedJob, args: [ @machine.id ]) do
        assert_equal 2, Analysis.retry_failed!
      end

      waiting = Analysis.parked.order(:id).to_a
      assert_equal [ @feed, other ], waiting.map(&:feed)
      assert_equal [ [ Analyzer::MODELS, @machine.id ] ], waiting.map { |held| [ held.waits_for, held.waits_on_id ] }.uniq
      assert_equal "remember the milk", waiting.first.step_result("text")

      assert_equal 0, Analysis.retry_failed!
    end
  end

  test "retrying failures looks only as far back as asked" do
    on_laptop

    Tenant.switch(@tenant) do
      Analysis.create!(feed: @feed, cause: "sync", status: "failed", error: "old", created_at: 3.days.ago)

      assert_equal 0, Analysis.retry_failed!(since: 1.day.ago)
      assert_equal 1, Analysis.retry_failed!(since: 4.days.ago)
    end
  end

  private

    def drained
      AnalyzeFeedJob::MOST_UNANSWERED.times { perform_enqueued_jobs(only: AnalyzeFeedJob, at: 1.hour.from_now) }
    end

    def closed_port
      @closed_port ||= TCPServer.open("127.0.0.1", 0) { |held| held.addr[1] }
    end

    def on_laptop
      Tenant.switch(@tenant) do
        Resource::OpenaiCompatible.create!(
          key: "ollama-laptop", name: "Ollama on laptop",
          details: { "base_url" => "http://100.64.0.9:11434/v1", "models" => { "default" => "qwen3:8b" } }
        ).tap(&:make_default_inference!)
      end
    end

    def asleep!
      Tenant.switch(@tenant) { @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge("connected" => false))) }
    end

    def awake!
      @machine.reload.update!(details: @machine.details.merge("machine" => @machine.machine.merge("connected" => true, "seen_at" => Time.current.utc.iso8601)))
    end

    def analyze
      analysis = Tenant.switch(@tenant) { @feed.analyze!(cause: "manual") }
      Tenant.switch(@tenant) { relaying { perform_enqueued_jobs(only: AnalyzeFeedJob) } }
      analysis
    end

    def chat_reply(payload)
      { "status" => 200, "content_type" => "text/event-stream",
        "body" => "data: #{{ choices: [ { delta: { content: payload.to_json } } ] }.to_json}\n\ndata: [DONE]\n\n" }
    end

    def relaying(&)
      missing = { "status" => 404, "content_type" => "application/json", "body" => "{}" }
      script = lambda do |_verb, args = {}, within: nil|
        raise Resource::Machine::Refusal, @refusal if @refusal
        next missing unless args["path"] == "/v1/chat/completions"

        @replies&.shift || raise(Resource::Unreachable, "laptop: xixo link did not answer relay in #{within.inspect}")
      end

      with_ask(script, &)
    end

    def with_ask(script)
      original = Resource::Machine.instance_method(:ask)
      Resource::Machine.define_method(:ask) do |verb, args = {}, within: Resource::Machine::ANSWERED_WITHIN|
        raise Resource::Offline, "#{key}: xixo link is not connected" unless connected?

        script.call(verb, args.to_h.deep_stringify_keys, within: within)
      end
      yield
    ensure
      Resource::Machine.define_method(:ask, original)
    end
end
