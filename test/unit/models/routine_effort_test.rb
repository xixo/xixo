require "test_helper"
require_relative "../../support/fake_model_server"

class RoutineEffortTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b")
    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "effort-#{SecureRandom.hex(4)}", name: "Effort")

    Tenant.switch(@tenant) do
      storage = Resource::Database.create!(key: "drop", name: "Drop")
      storage.upload("notes.txt", "remember the milk")
      @feed = Feed.create!(type: Feed::FILE, key: "notes.txt", title: "notes.txt")
      Reference.record!(feed: @feed, resource: storage, locator_key: "notes.txt", locator: { "key" => "notes.txt" })
    end
  end

  teardown { ENV.delete("XIXO_INFERENCE_ORIGINS") }

  def backend(**details)
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b" } }.merge(details)
      ).tap(&:make_default_inference!)
    end
  end

  def filed
    @server.answer("Found it.")
    address = Tenant.switch(@tenant) { Feed.create!(type: Feed::ADDRESS, key: "/milk").tap { |held| held.create_schedule!(prompt: "find milk") } }
    analysis = Tenant.switch(@tenant) { address.analyze! }
    Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, address.id, analysis.id) }
  end

  test "a routine run asks the model for the backend's routine effort" do
    backend("routine_effort" => "none")

    filed

    assert_equal [ "none" ], @server.efforts.uniq
  end

  test "a summary is routine work, and asks for the backend's routine effort" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "routine_effort" => "none",
                                  "models" => { "smart" => "qwen3:8b" } }
      ).tap(&:make_default_inference!)
    end
    @server.answer_json(summary: "A note about milk.", tags: [ "groceries" ])

    analysis = Tenant.switch(@tenant) { @feed.analyze!(cause: "manual") }
    Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, @feed.id, analysis.id) }

    assert_equal [ "none" ], @server.efforts.uniq
  end

  test "a backend with no routine effort asks the model not to think" do
    backend

    filed

    assert_equal [ "none" ], @server.efforts.uniq
  end

  test "a backend set to as the model likes sends no effort" do
    backend("routine_effort" => "model")

    filed

    assert_equal [ nil ], @server.efforts.uniq
  end

  test "a summary asked without thinking keeps the short budget, and one that may think gets the long one" do
    held = backend("models" => { "smart" => "qwen3:8b" })
    @server.answer_json(summary: "A note.", tags: [ "milk" ])
    Tenant.switch(@tenant) { held.summarize("Say it.", role: :smart) }

    Tenant.switch(@tenant) { held.update!(details: held.details.merge("routine_effort" => "model")) }
    @server.answer_json(summary: "A note.", tags: [ "milk" ])
    Tenant.switch(@tenant) { held.summarize("Say it.", role: :smart) }

    assert_equal [ Resource::OpenaiCompatible::MAX_TOKENS, Resource::OpenaiCompatible::AGENT_MAX_TOKENS ], @server.budgets
  end

  test "a model that thinks through its whole budget is told to stop thinking, in plain words" do
    held = backend("routine_effort" => "model", "models" => { "smart" => "qwen3:8b" })
    3.times { @server.answer_thinking("Hmm, let me think about the milk.") }

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { held.summarize("Say it.", role: :smart) } }

    assert_match(/spent its 8192 token budget thinking and wrote no answer. Set its effort on routine work to none/, error.message)
  end

  test "a server that refuses the effort is asked again without it" do
    held = backend("models" => { "smart" => "qwen3:8b" })
    @server.refuse(400, body: { error: "'reasoning_effort' must be one of low, medium, high" }.to_json)
    @server.answer_json(summary: "A note about milk.", tags: [ "milk" ])

    answered = Tenant.switch(@tenant) { held.summarize("Say it.", role: :smart) }

    assert_equal "A note about milk.", answered["summary"]
    assert_equal [ "none", nil ], @server.efforts
  end

  test "every agent is told today's date, and what it makes past and future" do
    backend

    filed

    assert_includes @server.systems.first, "Today is #{Date.current.strftime('%A, %B %-d, %Y')}."
    assert_includes @server.systems.first, "still to come"
  end

  test "a routine effort the api does not know is refused" do
    held = Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.new(key: "odd", details: { "base_url" => @server.base_url, "routine_effort" => "extreme" })
    end

    assert_not held.valid?
    assert_match(/routine_effort is one of none, minimal/, held.errors.full_messages.join)
  end
end
