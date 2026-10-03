require "test_helper"
require_relative "../../support/fake_model_server"

class ScoutingTest < ActiveSupport::TestCase
  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b", "gemma3:4b")
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "scout-#{SecureRandom.hex(4)}", name: "Scouting")

    Tenant.switch(@tenant) do
      @inference = Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b" } }
      )
      @feed = Feed.create!(type: Feed::NOTE, key: "question", title: "question")
      @analysis = Analysis.open!(feed: @feed, cause: "ask").tap(&:running!)
    end
  end

  teardown { ENV.delete("URIS_INFERENCE_ORIGINS") }

  def grant
    Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "test", "scope" => Feed::ASKING_SCOPES.join(" ")))
  end

  def raw(task)
    { "id" => "call_1", "type" => "function", "function" => { "name" => "scout", "arguments" => { task: task }.to_json } }
  end

  def scouting(**options)
    Scouting.new(grant: grant, analysis: @analysis, briefing: ->(task) { "Do this: #{task}" }, **options)
  end

  def within
    Tenant.switch(@tenant) do
      Current.grant = grant
      yield
    ensure
      Current.grant = nil
    end
  end

  test "a scout starts fresh with its briefing, and the lead gets back only its report" do
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("Found [feed 12].")

    held = scouting
    report = within { held.call_all([ raw("find the invoice") ]).first }

    assert report.ok
    assert_equal "Found [feed 12].", JSON.parse(report.content)["report"]
    assert_equal [ "search" ], held.calls.map(&:name)
    assert_match(/\ADo this: find the invoice/, @server.prompts.first)
  end

  test "a scout runs on the scout model when one is declared, and on the agent's otherwise" do
    2.times { @server.answer("Nothing.") }

    within do
      scouting.call_all([ raw("first") ])
      @inference.update!(details: @inference.details.merge("models" => { "agent" => "qwen3:8b", "scout" => "gemma3:4b" }))
      scouting.call_all([ raw("second") ])
    end

    assert_equal %w[qwen3:8b gemma3:4b], Tenant.switch(@tenant) { @analysis.reload.turns.map { |turn| turn["model"] } }
  end

  test "a scout that needs longer asks for more time, and the whole run gets it" do
    @server.answer_tool_call("more_time", minutes: 45, reason: "a long spreadsheet")
    @server.answer("Nothing.")

    before = @analysis.deadline
    held = scouting
    within { held.call_all([ raw("read the whole spreadsheet") ]) }

    assert held.calls.first.ok
    assert_in_delta before + 45.minutes, Tenant.switch(@tenant) { @analysis.reload.deadline }, 5
  end

  test "a scout stands down with time still on the clock, so the lead has room to answer" do
    Tenant.switch(@tenant) { @analysis.update_columns(deadline: 60.seconds.from_now) }

    report = within { scouting.call_all([ raw("find it") ]).first }

    assert_equal "halted", JSON.parse(report.content)["stopped"]
    assert_empty @server.prompts
  end

  test "a scout with no task, or no model to run on, is refused back to the lead rather than raising" do
    within do
      assert_match(/needs a task/, scouting.call_all([ raw("  ") ]).first.error)

      Resource.destroy_all

      refused = scouting.call_all([ raw("find it") ]).first

      assert_not refused.ok
      assert_match(/agent role/, refused.error)
    end
  end
end
