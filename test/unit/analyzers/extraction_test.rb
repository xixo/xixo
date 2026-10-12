require "test_helper"
require_relative "../../support/machines"

class ExtractionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "extract-#{SecureRandom.hex(4)}", name: "Extraction")
    @machine = agent_on(@tenant, folders: [ "/srv/notes" ])

    Tenant.switch(@tenant) do
      @machine.update_columns(details: @machine.details.deep_merge("machine" => { "extractors" => %w[text] }))
      @folder = Resource::AgentFolder.create!(key: "notes", name: "Notes", via: @machine, details: { "folder" => "/srv/notes" })
      @storage = Resource::Database.create!(key: "desk", name: "Desk")
    end
  end

  test "a file on a machine is read by that machine's agent, where it lies" do
    feed = Tenant.switch(@tenant) { on_machine("plan.txt") }
    asked = []

    answering(asked, { "text" => "the plan" }) { analyze(feed) }

    assert_equal [ { "folder" => "/srv/notes", "path" => "plan.txt" } ],
                 asked.filter_map { |verb, args| args["source"] if verb == "extract" }
    assert_empty FakeAgent.asked
    Tenant.switch(@tenant) { assert_equal "the plan", feed.reload.analysis.step_result("text") }
  end

  test "a file its machine cannot read is sent to the agent beside the server" do
    feed = Tenant.switch(@tenant) { on_machine("budget.pdf") }
    read = ->(*) { Tempfile.new("read").tap { |file| file.write("%PDF bytes") && file.rewind } }

    with_method(Resource::XixoAgent, :read, read) { analyze(feed) }

    assert_equal "%PDF bytes", FakeAgent.asked.last.bytes
    assert_equal FakeAgent.asked.last.args.dig("source", "upload"), FakeAgent.forgotten.last
  end

  test "with no agent connected, analysis waits and is tried again" do
    FakeAgent.standing = false
    feed = Tenant.switch(@tenant) { stored("notes.txt", "remember the milk") }
    analysis = Tenant.switch(@tenant) { Analysis.open!(feed: feed, cause: "manual") }

    assert_enqueued_with(job: AnalyzeFeedJob) do
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, feed.id, analysis.id) }
    end

    Tenant.switch(@tenant) do
      assert analysis.reload.open?
      assert_match(/no agent beside the server/, analysis.step("extracted").dig("error", "message"))
    end
  end

  test "an agent beside the server without the extractor fails the file with the reason" do
    FakeAgent.local.extractors = %w[text]
    feed = Tenant.switch(@tenant) { stored("plan.pdf", "%PDF") }

    analyze(feed)

    Tenant.switch(@tenant) do
      assert_match(/has no pdf extractor/, feed.reload.analysis.step("extracted").dig("error", "message"))
    end
  end

  test "a text longer than the server reads is cut and says so, however long the agent sent" do
    FakeAgent.script = ->(*) { FakeAgent.extracted({ "text" => "x" * (Analyzer::Base::MAX_TEXT + 10) }) }
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

    def answering(asked, steps, &)
      exchanged = lambda do |verb, args = {}, within: nil, &block|
        asked << [ verb, args ]
        next block.call(FakeAgent::Answer.new({ "size" => 0 }, {})) if verb == "read"

        result, held = FakeAgent.extracted(steps)
        block.call(FakeAgent::Answer.new(result.deep_stringify_keys, held))
      end

      with_method(Resource::XixoAgent, :exchanged, exchanged, &)
    end

    def with_method(klass, name, body)
      original = klass.instance_method(name)
      klass.define_method(name, &body)
      yield
    ensure
      klass.define_method(name, original)
    end
end
