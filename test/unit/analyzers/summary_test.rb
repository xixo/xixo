require "test_helper"
require_relative "../../support/fake_model_server"

class SummaryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NOTES = "The quarterly pelican census for the northern colony. " \
          "Counts were taken weekly across four sites, and the population rose by a fifth. " \
          "Needle: NOTES-4820. Filed by the survey team for the trustees. " \
          "The estuary sites were counted at low tide, which is when the birds gather on the " \
          "sandbars and can be told apart from the gulls. Two of the four sites were new this " \
          "quarter, so the year-on-year comparison covers only the older pair."

  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("gemma3:4b", "llama3.1:8b")

    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "sum-#{SecureRandom.hex(4)}", name: "Summaries")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "disk", name: "Storage")
      @storage.make_default_storage!

      store("notes.txt", NOTES)
    end

    sync
  end

  teardown do
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end

  test "with no inference resource the summary step is absent, and analysis still finishes" do
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      steps = steps_at("notes.txt")

      assert steps.key?("text")
      assert_not steps.key?("summary")
      assert reference("notes.txt").analyzed_at.present?
    end

    assert_equal 0, @server.count_for("/v1/chat/completions")
  end

  test "configuring inference afterwards fills the summary in without recomputing text" do
    analyze "notes.txt"

    before = Tenant.switch(@tenant) { steps_at("notes.txt").dig("text", "finished_at") }

    inference!
    @server.answer_json({ summary: "A pelican census.", keywords: %w[pelican census] })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      steps = steps_at("notes.txt")

      assert_equal before, steps.dig("text", "finished_at")
      assert_equal "A pelican census.", steps.dig("summary", "result", "summary")
      assert_equal %w[pelican census], steps.dig("summary", "result", "keywords")
    end
  end

  test "the default prompt is built over the text step" do
    inference!
    @server.answer_json({ summary: "ok" })
    analyze "notes.txt"

    assert_includes @server.prompts.last, "NOTES-4820"
    assert_includes @server.prompts.last, "data, not"
  end

  test "the summary reaches the search index" do
    inference!
    @server.answer_json({ summary: "A study of wading birds in the estuary.", keywords: [ "estuary" ] })
    analyze "notes.txt"
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      assert_equal [ "notes.txt" ], Feed.search("estuary").pluck(:title)
    end
  end

  test "the summary is what the endpoint hands back, and an error surfaces as its message" do
    inference!
    @server.answer_json({ summary: "A pelican census." })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      assert_equal "A pelican census.",
                   Tool::Feeds.told(feed_at("notes.txt"))[:steps].dig("summary", "summary")
    end

    @server.refuse(404, body: "no such model")
    Tenant.switch(@tenant) { @inference.update!(details: @inference.details.merge("models" => { "smart" => "gemma3:4b" })) }
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      assert_match(/404/, Tool::Feeds.told(feed_at("notes.txt"))[:steps].dig("summary", "error"))
    end
  end

  test "provenance is recorded on the step but never indexed" do
    inference!
    @server.answer_json({ summary: "A pelican census." })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      step = steps_at("notes.txt").dig("summary")

      assert_equal "ollama", step["resource"]
      assert_equal "llama3.1:8b", step["model"]
      assert_equal "smart", step["role"]

      assert_not_includes feed_at("notes.txt").body_text, "llama3.1:8b"
      assert_not_includes feed_at("notes.txt").body_text, "ollama"
    end
  end

  test "a second analysis does not call the model again" do
    inference!
    @server.answer_json({ summary: "A pelican census." })
    analyze "notes.txt"
    analyze "notes.txt"

    assert_equal 1, @server.count_for("/v1/chat/completions")
  end

  test "re-pointing the resource at another model re-runs the summary exactly once" do
    inference!
    @server.answer_json({ summary: "first" })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      @inference.update!(details: @inference.details.merge("models" => { "smart" => "gemma3:4b" }))
    end

    @server.answer_json({ summary: "second" })
    analyze "notes.txt"
    analyze "notes.txt"

    assert_equal 2, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      assert_equal "second", steps_at("notes.txt").dig("summary", "result", "summary")
    end
  end

  test "text that reads differently is summarized again, and the same text is not" do
    inference!
    @server.answer_json({ summary: "first" })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      held = analysis_at("notes.txt").step("text")
      analysis_at("notes.txt").write_step!("text", held.merge("result" => "#{NOTES} A second reading found more."))
    end

    @server.answer_json({ summary: "second" })
    analyze "notes.txt"
    analyze "notes.txt"

    assert_equal 2, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      assert_equal "second", steps_at("notes.txt").dig("summary", "result", "summary")
    end
  end

  test "a long text is summarized from summaries of its parts, all on the summary model" do
    inference!
    long = (1..350).map { |line| "Line #{line} of the long pelican report counts birds at the estuary." }.join("\n")
    Tenant.switch(@tenant) { store("long.txt", long) }
    sync

    3.times { |part| @server.answer_json({ summary: "Part #{part + 1} counts pelicans." }) }
    @server.answer_json({ summary: "A long pelican report." })
    analyze "long.txt"

    Tenant.switch(@tenant) do
      steps = steps_at("long.txt")

      assert_equal [ "Part 1 counts pelicans.", "Part 2 counts pelicans.", "Part 3 counts pelicans." ],
                   steps.dig("sections", "result")
      assert_equal "A long pelican report.", steps.dig("summary", "result", "summary")
    end

    assert_match(/part 1 of 3 of a file/, @server.prompts.first)
    assert_match(/read in 3 parts.*1\. Part 1 counts pelicans\./m, @server.prompts.last)

    analyze "long.txt"

    assert_equal 4, @server.count_for("/v1/chat/completions"), "the parts are read once"
  end

  test "a health check does not re-summarize the catalog" do
    inference!
    @server.answer_json({ summary: "first" })
    analyze "notes.txt"

    Tenant.switch(@tenant) { @inference.check }

    analyze "notes.txt"

    assert_equal 1, @server.count_for("/v1/chat/completions")
  end

  test "keywords returned as a string are coerced into a list" do
    inference!
    @server.answer_json({ summary: "ok", keywords: "pelican, census, estuary" })
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      assert_equal %w[pelican census estuary],
                   steps_at("notes.txt").dig("summary", "result", "keywords")
    end
  end

  test "a document too short to have been worth extracting is summarized anyway" do
    Tenant.switch(@tenant) { store("tiny.txt", "too short") }
    sync
    inference!
    @server.answer_json("summary" => "A two-word note reading \"too short\".",
                        "keywords" => [ "too short" ])

    analyze "tiny.txt"

    assert_equal 1, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      assert steps_at("tiny.txt").dig("summary", "result", "summary").present?
    end
  end

  test "a rejected model records an error on the step but leaves extraction standing" do
    inference!
    @server.refuse(404, body: "no such model")
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      steps = steps_at("notes.txt")

      assert_includes steps.dig("text", "result"), "NOTES-4820"
      assert steps.dig("summary", "error").present?
      assert reference("notes.txt").analyzed_at.present?

      assert_equal "ollama", steps.dig("summary", "resource")
      assert_equal "llama3.1:8b", steps.dig("summary", "model")
    end
  end

  test "a server error is retried rather than discarded" do
    inference!
    @server.refuse(500)

    id = Tenant.switch(@tenant) { feed_at("notes.txt").id }

    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, id) }
    end
  end

  test "a rejected model is discarded rather than retried" do
    inference!
    @server.refuse(404, body: "no such model")

    id = Tenant.switch(@tenant) { feed_at("notes.txt").id }

    assert_no_enqueued_jobs do
      assert_nothing_raised { Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, id) } }
    end
  end

  test "every attempt is recorded as its own turn on the analysis" do
    inference!
    3.times { @server.answer("not json at all") }
    analyze "notes.txt"

    Tenant.switch(@tenant) do
      turns = summary_turns("notes.txt")

      assert_equal [ 1, 2, 3 ], turns.map { |turn| turn["n"] }
      assert_equal [ "llama3.1:8b" ], turns.map { |turn| turn["model"] }.uniq
    end
  end

  test "a kind that extracts no text is described from what can be seen of it" do
    inference!

    @server.answer_json("summary" => "A 21-byte binary file named mystery.bin. Its contents were not read.",
                        "keywords" => [ "mystery.bin" ])

    Tenant.switch(@tenant) { store("mystery.bin", "\x01\x02\x03 not text at all") }
    sync
    analyze "mystery.bin"

    Tenant.switch(@tenant) do
      steps = steps_at("mystery.bin")

      assert_not steps.key?("text")
      assert_equal "binary", steps.dig("format", "result", "observed")
      assert steps.dig("summary", "result", "summary").present?
    end

    assert_includes @server.prompts.last, "No text could be read out of this file"
  end

  test "a file nothing claims but that is plainly text is read rather than weighed" do
    inference!

    @server.answer_json("summary" => "An access log of order and refund requests.",
                        "keywords" => [ "orders", "refunds" ])

    Tenant.switch(@tenant) { store("server.log", "GET /orders/4820 200\nPOST /refunds 500\n" * 8) }
    sync
    analyze "server.log"

    Tenant.switch(@tenant) do
      steps = steps_at("server.log")

      assert_equal "text", steps.dig("format", "result", "observed")
      assert_includes steps.dig("text", "result"), "/orders/4820"
    end

    assert_includes @server.prompts.last, "/orders/4820"
  end

  private

    def inference!
      Tenant.switch(@tenant) do
        @inference = Resource::OpenaiCompatible.create!(
          key: "ollama", name: "Local models",
          details: { "base_url" => @server.base_url,
                     "models" => { "smart" => "llama3.1:8b", "fast" => "gemma3:4b" } }
        )
        @inference.make_default_inference!
      end
    end

    def store(key, body)
      @storage.upload(key, body)
    end

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id) }
    end

    def analyze(key)
      analyze_feed_at(key)
    end

    def summary_turns(key)
      feed_at(key).analysis.turns.select { |turn| turn["role"] == "smart" }
    end

    def reference(key)
      Reference.find_by!(locator_key: key).reload
    end
end
