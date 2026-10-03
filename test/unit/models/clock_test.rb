require "test_helper"
require_relative "../../support/fake_model_server"

class ClockTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b")
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "clock-#{SecureRandom.hex(4)}", name: "Clock")

    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(key: "ollama", details: { "base_url" => @server.base_url,
                                                                   "models" => { "agent" => "qwen3:8b" } })
      @feed = Feed.create!(type: Feed::NOTE, key: "slow", title: "slow")
    end
  end

  teardown { ENV.delete("URIS_INFERENCE_ORIGINS") }

  def grant
    Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "test", "scope" => Feed::AGENT_SCOPES.join(" ")))
  end

  def opened
    Analysis.open!(feed: @feed, cause: "manual").tap(&:running!)
  end

  def run_agent(analysis, turns: 6)
    held = grant
    Current.grant = held
    Agent.new(grant: held, analysis: analysis, turns: turns, halted: -> { analysis.halted? }).call("take your time")
  ensure
    Current.grant = nil
  end

  test "an analysis runs for its feed's timeout from when it starts, not from when it was queued" do
    Tenant.switch(@tenant) do
      queued = Analysis.open!(feed: @feed, cause: "manual")

      travel 20.minutes do
        queued.running!

        assert_in_delta Feed::TIMEOUT.from_now, queued.deadline, 1
        assert_in_delta Feed::TIMEOUT.from_now, queued.reload.deadline, 1
      end

      @feed.update!(timeout: 2.hours.to_i)

      assert_in_delta 2.hours.from_now, Analysis.open!(feed: @feed, cause: "manual").tap(&:running!).deadline, 1
    end
  end

  test "the agent is told how long it has, and asking for more moves the deadline" do
    @server.answer_tool_call("more_time", minutes: 30, reason: "there are forty pages to read")
    @server.answer("Done.")

    Tenant.switch(@tenant) do
      analysis = opened
      answered = run_agent(analysis)

      assert_equal "Done.", answered.said
      assert_in_delta (Feed::TIMEOUT + 30.minutes).from_now, analysis.reload.deadline, 5
      assert_match(/more_time.*30 minutes.*forty pages/, analysis.logs)
    end
  end

  test "more time never runs past a day from the start, however it is asked for" do
    3.times { @server.answer_tool_call("more_time", minutes: 1_000, reason: "more") }
    @server.answer("Done.")

    Tenant.switch(@tenant) do
      analysis = opened
      run_agent(analysis)

      assert_in_delta analysis.started_at + 1.day, analysis.reload.deadline, 1
    end
  end

  test "asking for no time, or without saying why, is refused" do
    @server.answer_tool_call("more_time", minutes: 0, reason: "none")
    @server.answer_tool_call("more_time", minutes: 10)
    @server.answer("Done.")

    Tenant.switch(@tenant) do
      analysis = opened
      before = analysis.deadline
      answered = run_agent(analysis)

      assert_equal [ false, false ], answered.calls.map(&:ok)
      assert_in_delta before, analysis.reload.deadline, 1
    end
  end

  test "with under a minute left, the next turn is the last, and it answers rather than being cut off" do
    @server.answer("From what I had.")

    Tenant.switch(@tenant) do
      analysis = opened
      analysis.update_columns(deadline: 30.seconds.from_now)

      answered = run_agent(analysis)

      assert_equal :answered, answered.reason
      assert_equal 1, answered.turns
      assert_match(/no turns left and no tools/, @server.prompts.last)
    end
  end

  test "an agent with no analysis has no clock and is not offered more time" do
    @server.answer("Done.")

    Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      agent = Agent.new(grant: held)
      agent.call("anything")

      assert_empty Agent::Clock.new(nil).declared
    ensure
      Current.grant = nil
    end
  end
end
