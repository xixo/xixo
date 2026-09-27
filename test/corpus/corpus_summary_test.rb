require "test_helper"
require_relative "../support/fake_model_server"

class CorpusSummaryTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("test/fixtures/corpus")

  SOURCES = %w[text/readme.md data/rows.csv pdf/invoice.pdf xlsx/budget.xlsx calendar/meeting.ics].freeze

  setup do
    skip "no corpus on disk — see test/fixtures/corpus/README.md" unless CORPUS.directory?

    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("llama3.1:8b")

    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "cor-#{SecureRandom.hex(4)}", name: "Corpus")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "disk", name: "Storage")
      @storage.make_default_storage!

      @inference = Resource::OpenaiCompatible.create!(
        key: "ollama",
        details: { "base_url" => @server.base_url, "models" => { "smart" => "llama3.1:8b" } }
      )
      @inference.make_default_inference!
    end
  end

  teardown do
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end

  SOURCES.each do |path|
    test "what #{path} extracts is what the model is asked about" do
      source = CORPUS.join(path)
      skip "#{path} is not in the corpus" unless source.exist?

      name = File.basename(path)

      Tenant.switch(@tenant) { @storage.upload(name, source.read) }
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id) }

      @server.answer_json({ summary: "It concerns CORPUSECHO-7781.", tags: [ "corpusecho" ] })

      id = Tenant.switch(@tenant) do
        Feed.joins(:references).find_by!(feed_references: { locator_key: name }).id
      end
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, id) }

      needle = needle_in(source)
      assert_includes @server.prompts.last, needle if needle

      SearchIndex.refresh!

      Tenant.switch(@tenant) do
        assert_includes steps_at(name).dig("summary", "result", "summary"),
                        "CORPUSECHO-7781"

        assert_equal [ name ], Feed.search("CORPUSECHO-7781").pluck(:title)
      end
    end
  end

  private

    def needle_in(source)
      source.read.force_encoding("UTF-8").scrub[/[A-Z][A-Z0-9]+-\d{4}/]
    rescue StandardError
      nil
    end
end
