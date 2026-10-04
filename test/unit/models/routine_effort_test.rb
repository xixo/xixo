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

  test "a backend with no routine effort lets the model think as it likes" do
    backend

    filed

    assert_equal [ nil ], @server.efforts.uniq
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
