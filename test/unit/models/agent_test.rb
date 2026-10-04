require "test_helper"
require_relative "../../support/fake_model_server"

class AgentTest < ActiveSupport::TestCase
  MODELS = { "agent" => "qwen3:8b" }.freeze

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves(MODELS.values)

    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "agent-#{SecureRandom.hex(4)}", name: "Agent")

    Tenant.switch(@tenant) do
      @inference = Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => @server.base_url, "models" => MODELS }
      )
      @feed = Feed.create!(type: Feed::NOTE, key: "invoice.md", title: "Acme invoice")
    end
  end

  teardown { ENV.delete("XIXO_INFERENCE_ORIGINS") }

  def grant(scopes = Feed::AGENT_SCOPES)
    Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new(
      "sub" => "test", "scope" => scopes.join(" ")
    ))
  end

  def run_agent(turns: 6, analysis: nil)
    Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      Agent.new(grant: held, analysis: analysis, turns: turns).call("what is the invoice for?")
    ensure
      Current.grant = nil
    end
  end

  test "it calls a tool, reads the result, and answers" do
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("The Acme invoice is for $4,200.")

    answered = run_agent

    assert_equal :answered, answered.reason
    assert_equal "The Acme invoice is for $4,200.", answered.said
    assert_equal 2, answered.turns
    assert_equal [ "search" ], answered.calls.map(&:name)
    assert answered.calls.first.ok
  end

  test "an argument the model invented comes back as something it can correct" do
    @server.answer_tool_call("connect", a: "1", b: "2", because: "they rhyme")
    @server.answer("Connected them.")

    answered = run_agent

    assert_equal :answered, answered.reason
    assert_equal 2, answered.turns
    assert_equal 1, answered.calls.length
  end

  test "a missing required argument is refused rather than raised" do
    @server.answer_tool_call("connect", b: "1")
    @server.answer("I could not.")

    answered = nil
    assert_nothing_raised { answered = run_agent }

    refused = answered.calls.first

    assert_not refused.ok
    assert_match(/needs a/, refused.error)
    assert_equal :answered, answered.reason
  end

  test "a tool it was never offered is named rather than dispatched" do
    @server.answer_tool_call("sync_everything", {})
    @server.answer("There is no such tool.")

    answered = run_agent
    refused = answered.calls.first

    assert_not refused.ok
    assert_match(/no tool named sync_everything/, refused.error)
    assert_match(/search/, refused.error)
  end

  test "arguments that are not JSON are refused rather than raised" do
    refused = dispatched("search", "{not json at all")

    assert_not refused.ok
    assert_match(/not valid JSON/, refused.error)
  end

  test "an argument of the wrong type is refused by the tool's own schema" do
    refused = dispatched("search", { limit: "fifty" }.to_json)

    assert_not refused.ok
    assert_match(/limit/, refused.error)
  end

  def dispatched(name, arguments)
    Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      offered = held.tools.select { |tool| Agent::READ_TOOLS.include?(tool.tool_name) }

      Agent::Dispatch.new(offered: offered, context: {}).call(
        { "id" => "call_0", "function" => { "name" => name, "arguments" => arguments } }
      )
    ensure
      Current.grant = nil
    end
  end

  test "three malformed calls in a row stop the run rather than burning every turn" do
    4.times { @server.answer_tool_call("connect", a: "1") }
    @server.answer("never reached")

    answered = run_agent(turns: 12)

    assert_equal :flailed, answered.reason
    assert_equal 3, answered.calls.length
    assert answered.calls.none?(&:ok)
  end

  test "the last turn is offered no tools, so a budget that runs out still answers" do
    3.times { @server.answer_tool_call("search", query: "invoice") }
    @server.answer("It is for $4,200.")

    answered = run_agent(turns: 4)

    assert_equal :answered, answered.reason
    assert_equal "It is for $4,200.", answered.said
    assert_equal 4, answered.turns
    assert_match(/no turns left and no tools/, @server.prompts.last)
  end

  test "a halt between turns stops before spending another one" do
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("unreached")

    answered = Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      Agent.new(grant: held, turns: 6, halted: -> { true }).call("anything")
    ensure
      Current.grant = nil
    end

    assert_equal :halted, answered.reason
    assert_equal 0, answered.turns
  end

  test "an answer that is not finished is turned back once, and the second answer stands" do
    @server.answer("From the snippets alone.")
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("Still from the snippets.")

    asked = []
    answered = Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      Agent.new(grant: held, turns: 6, unfinished: ->(calls) { asked << calls.size; "Read the pages first." })
           .call("anything")
    ensure
      Current.grant = nil
    end

    assert_equal :answered, answered.reason
    assert_equal "Still from the snippets.", answered.said
    assert_equal 3, answered.turns
    assert_equal [ 0, 1 ], asked
    assert_match(/Read the pages first/, @server.prompts[1])
  end

  test "a tool call written out as text is turned back to be made, and prose with json in it is not" do
    @server.answer(%(I'll fetch it now:\n```json\n{"do": "get", "key": "curl", "input": {"url": "https://example.com"}}\n```))
    @server.answer_tool_call("search", query: "invoice")
    @server.answer(%(The invoice reads {"total": 4200, "currency": "USD"}.))

    answered = run_agent

    assert_equal :answered, answered.reason
    assert_equal 3, answered.turns
    assert_match(/wrote a tool call out as text/, @server.prompts[1])
    assert_match(/4200/, answered.said)
  end

  test "an unfinished answer on the last turn stands rather than spending a turn it does not have" do
    @server.answer("From the snippets alone.")

    answered = Tenant.switch(@tenant) do
      held = grant
      Current.grant = held
      Agent.new(grant: held, turns: 1, unfinished: ->(_) { "Read the pages first." }).call("anything")
    ensure
      Current.grant = nil
    end

    assert_equal "From the snippets alone.", answered.said
    assert_equal 1, answered.turns
  end

  test "every turn and every call is recorded on the analysis" do
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("The Acme invoice is for $4,200.")

    analysis = Tenant.switch(@tenant) { Analysis.open!(feed: @feed, cause: "manual") }

    run_agent(analysis: analysis)

    Tenant.switch(@tenant) { analysis.reload }

    assert_equal 2, analysis.turns.length
    assert_equal [ 1, 2 ], analysis.turns.map { |turn| turn["n"] }
    assert_equal [ "search" ], analysis.turns.first["calls"]
    assert_match(/search/, analysis.logs)
  end

  test "it refuses when no resource serves the agent role" do
    Tenant.switch(@tenant) { @inference.update!(details: @inference.details.merge("models" => {})) }

    assert_raises(Agent::Refused) do
      Tenant.switch(@tenant) { Agent.new(grant: grant, inference: nil).call("anything") }
    end
  end
end
