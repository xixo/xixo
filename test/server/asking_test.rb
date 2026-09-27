require "test_helper"
require_relative "../support/fake_model_server"

class AskingTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ASK = <<~GQL.freeze
    mutation($question: String!) {
      askCatalog(input: { question: $question }) { feed { id title } analysis { id status } }
    }
  GQL

  FOLLOW_UP = <<~GQL.freeze
    mutation($id: ID!, $question: String!) {
      askCatalog(input: { question: $question, feedId: $id }) { feed { id } analysis { id question } }
    }
  GQL

  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b")
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "ask-#{SecureRandom.hex(4)}", name: "Ask")

    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b" } }
      )
      @invoice = Feed.create!(type: Feed::NOTE, key: "Acme invoice", title: "Acme invoice")
      @other = Feed.create!(type: Feed::NOTE, key: "Beach photo", title: "Beach photo")
    end

    connect!(@tenant)
  end

  teardown { ENV.delete("URIS_INFERENCE_ORIGINS") }

  test "a question is kept as a note, answered from what a scout reported, and connected to what it cites" do
    scout("Find the Acme invoice's total") do
      @server.answer_tool_call("search", query: "invoice")
      @server.answer_tool_call("feed", id: @invoice.id.to_s)
      @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    end
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal Feed::NOTE, note.type
      assert_equal "feed", note.origin
      assert_equal "ask", analysis.cause
      assert_equal "done", analysis.status
      assert_match(/\$4,200/, analysis.step_result("text"))
      assert_equal [ @invoice.id ], note.connected.pluck(:id)
      assert_match(/lead : turn 1 : scout/, analysis.logs)
      assert_match(/scout 1 : turn 1 : search/, analysis.logs)
      assert_match(/scout 1 : turn 2 : feed/, analysis.logs)
    end

    assert(@server.prompts.any? { |prompt| prompt.include?("judged against today") && prompt.include?(Today.said) },
           "the judges are told the date an answer's claims about time are held to")
  end

  test "a question is thought through however hard the backend lets routine work skimp" do
    Tenant.switch(@tenant) do
      held = Resource::OpenaiCompatible.find_by!(key: "ollama")
      held.update!(details: held.details.merge("routine_effort" => "none"))
    end

    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_operator @server.efforts.size, :>, 1
    assert_equal [ nil ], @server.efforts.uniq
  end

  ABOUT = <<~GQL.freeze
    mutation($question: String!, $about: ID) {
      askCatalog(input: { question: $question, aboutId: $about }) { feed { id } analysis { id } }
    }
  GQL

  test "a question about an item is connected to it, and its lead and scouts are told to open it first" do
    asked = execute(ABOUT, question: "When is it due?", about: @invoice.id.to_s).dig("data", "askCatalog")

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal @invoice, analysis.about
      assert_includes note.connected, @invoice

      asking = Asking.new(note, analysis: analysis)
      assert_match(/The question is about \[feed #{@invoice.id}\] \(Acme invoice\)\. Open it with feed first/, asking.prompt)
      assert_match(/\[feed #{@invoice.id}\]/, asking.briefing("find the due date"))

      later = Analysis.create!(feed: note, cause: "ask", question: "and who sent it?", steps: {})
      assert_match(/about \[feed #{@invoice.id}\]/, Asking.new(note, analysis: later).prompt, "a follow-up keeps what it is about")
    end
  end

  test "a question about an item that is not there is refused" do
    body = execute(ABOUT, question: "When is it due?", about: "999999")

    assert_match(/no feed with id 999999/, body.dig("errors", 0, "message"))
  end

  test "a follow-up is asked in the same note, told what was asked before, and the whole conversation is rolled up" do
    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    scout("Find when the Acme invoice is due") { @server.answer("It is due on 1 October [feed #{@other.id}].") }
    @server.answer("It is due on 1 October [feed #{@other.id}].")
    followed = follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal first.dig("feed", "id"), followed.dig("feed", "id"), "the follow-up stays in the note it follows"

    lead = @server.prompts.reverse.find { |prompt| prompt.include?("When is it due?") && prompt.include?("It follows on from") }
    assert lead, "the lead of the follow-up is told the conversation so far"
    assert_match(/Asked: How much is the Acme invoice\?\nAnswered: The Acme invoice is for \$4,200/, lead)

    passes = graphql("query($id: ID) { feed(id: $id) { analyses { cause question said drewOn { id } } } }",
                     id: first.dig("feed", "id")).dig("feed", "analyses").select { |pass| pass["cause"] == "ask" }.reverse

    assert_equal [ "How much is the Acme invoice?", "When is it due?" ], passes.pluck("question")
    assert_equal "It is due on 1 October [feed #{@other.id}].", passes.last["said"]
    assert_equal [ [ @invoice.id.to_s ], [ @other.id.to_s ] ], passes.map { |pass| pass["drewOn"].pluck("id") },
                 "each answer keeps what it drew on, though the note is connected to all of it"

    Tenant.switch(@tenant) do
      rolled = Analysis.find(followed.dig("analysis", "id")).step_result("conversation")

      assert_match(/Asked: How much is the Acme invoice\?.*\$4,200.*Asked: When is it due\?\nAnswered: It is due on 1 October/m, rolled)
      assert_equal [ @invoice.id, @other.id ].sort, Feed.find(first.dig("feed", "id")).connected.pluck(:id).sort
      assert_includes Feed.find(first.dig("feed", "id")).body_text, "1 October"
    end
  end

  test "once the reply lands the note is catalogued again from the whole conversation" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.find_by!(key: "ollama")
        .update!(details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b", "smart" => "qwen3:8b" } })
    end

    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    10.times { @server.answer_json(answered: true, useful: true, why: "it says so") }
    @server.answer_json(title: "Acme invoice")
    @server.answer_json(summary: "Asked what the Acme invoice costs: $4,200.", entities: [ "Acme" ], keywords: [ "Acme invoice" ])
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    scout("Find when it is due") { @server.answer("1 October.") }
    @server.answer("It is due on 1 October.")
    10.times { @server.answer_json(answered: true, useful: true, why: "it says so") }
    @server.answer_json(summary: "The Acme invoice is $4,200, due on 1 October.", entities: [ "Acme", "1 October" ],
                        keywords: [ "Acme invoice", "due date" ])
    follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    summarised = @server.prompts.reverse.find { |prompt| prompt.include?("Catalogue the conversation") }
    assert_match(/Asked: How much is the Acme invoice\?.*Asked: When is it due\?/m, summarised)

    note = graphql("query($id: ID) { feed(id: $id) { summary keywords } }", id: first.dig("feed", "id"))["feed"]

    assert_equal "The Acme invoice is $4,200, due on 1 October.", note["summary"]
    assert_includes note["keywords"], "due date"
  end

  test "a question is kept untitled and named by the fast model before the scouts set out" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.find_by!(key: "ollama")
        .update!(details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b", "fast" => "qwen3:8b" } })
    end

    @server.answer_json(title: "Vancouver weather today, please and thank you")
    scout("Find the weather in Vancouver") { @server.answer("14°C and raining.") }
    @server.answer("It is 14°C and raining in Vancouver.")

    asked = ask("can you check the weather for vancouver on https://open-meteo.com/")

    assert_nil asked.dig("feed", "title"), "a question is not its own title"

    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))

      assert_equal "Vancouver weather today, please and thank", note.title
      assert_equal "can you check the weather for vancouver on https://open-meteo.com/", note.key
      assert_equal "can you check the weather for vancouver on https://open-meteo.com/", note.conversation.first.question
    end

    named = @server.prompts.find { |prompt| prompt.include?("Name the question") }
    lead = @server.prompts.index { |prompt| prompt.include?("You lead scouts") || prompt.include?("Send scouts with scout") }
    assert named, "the fast model is asked for a title"
    assert_operator @server.prompts.index(named), :<, lead, "before the lead sends anyone"
  end

  test "with no fast model the note is named later, by the slower model, once the answer is in" do
    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    10.times { @server.answer_json(answered: true, useful: true, why: "it says so") }
    @server.answer_json(title: "Acme invoice total")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    named = @server.prompts.index { |prompt| prompt.include?("Name the question") }
    judged = @server.prompts.rindex { |prompt| prompt.include?("Respond with JSON: {\"answered\"") }

    assert_operator named, :>, judged, "named after the answer, not before the scouts"
    Tenant.switch(@tenant) { assert_equal "Acme invoice total", Feed.find(asked.dig("feed", "id")).title }
  end

  test "a follow-up waits for the question before it to be answered" do
    first = ask("How much is the Acme invoice?")
    refused = execute(FOLLOW_UP, id: first.dig("feed", "id"), question: "When is it due?")

    assert_nil refused.dig("data", "askCatalog")
    assert_match(/still being answered/, refused.dig("errors", 0, "message"))
  end

  test "a note nobody asked cannot be followed up" do
    refused = execute(FOLLOW_UP, id: @invoice.id.to_s, question: "When is it due?")

    assert_match(/never asked/, refused.dig("errors", 0, "message"))
  end

  test "asking again asks the latest question in the conversation" do
    scout("Find it") { @server.answer("$4,200.") }
    @server.answer("$4,200.")
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)
    scout("Find the date") { @server.answer("1 October.") }
    @server.answer("1 October.")
    follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    again = graphql("mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id } } }", id: first.dig("feed", "id"))

    Tenant.switch(@tenant) { assert_equal "When is it due?", Analysis.find(again.dig("analyzeFeed", "analysis", "id")).question }
  end

  test "the lead is turned back when it answers without sending a scout" do
    @server.answer("From memory, it is $4,200.")
    scout("Find the Acme invoice's total") { @server.answer("Nothing found.") }
    @server.answer("The scouts found nothing.")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_match(/lead : turn 1 : pressed : You have not sent a scout/, analysis.logs)
      assert_equal "The scouts found nothing.", analysis.step_result("text")
    end
  end

  test "several scouts sent in one turn each report back to the lead" do
    @server.answer_tool_calls([ [ "scout", { task: "Find the invoice" } ], [ "scout", { task: "Find the photo" } ] ])
    @server.answer("The invoice is [feed #{@invoice.id}].")
    @server.answer("The photo is [feed #{@other.id}].")
    @server.answer("Both are here: [feed #{@invoice.id}] and [feed #{@other.id}].")

    asked = ask("Where are the invoice and the photo?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal 2, analysis.logs.scan(/\[✓\] : lead : turn 1 : scout/).size
      assert(%w[invoice photo].all? { |thing| analysis.turns.any? { |turn| turn["request"].to_s.include?("Find the #{thing}") } },
             "each scout was briefed with its own task")
      assert_equal [ @invoice.id, @other.id ].sort, Feed.find(asked.dig("feed", "id")).connected.pluck(:id).sort
    end
  end

  test "an answered question reads cleanly in the catalog, and asking it again asks rather than analyzes" do
    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    note = graphql("query($id: ID) { feed(id: $id) { asked summary analyzedAt } }", id: asked.dig("feed", "id"))["feed"]

    assert note["asked"]
    assert_equal "The Acme invoice is for $4,200.", note["summary"]
    assert note["analyzedAt"].present?

    again = graphql("mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id } } }", id: asked.dig("feed", "id"))

    Tenant.switch(@tenant) { assert_equal "ask", Analysis.find(again.dig("analyzeFeed", "analysis", "id")).cause }
  end

  test "the question is never its own source, and scouts are told the web search when the tenant has one" do
    Tenant.switch(@tenant) do
      Resource::Search.create!(key: "exa", details: { "provider" => "exa" }, credentials: { "api_key" => "k" })
    end
    scout("Search the catalog for hn algolia") do
      @server.answer_tool_call("search", query: "hn algolia")
      @server.answer("Nothing in the catalog.")
      @server.answer("Nothing on the web either.")
    end
    @server.answer("Nothing in the catalog.")

    asked = ask("can you see hn algolia")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert(analysis.turns.none? { |turn| turn["request"].to_s.include?(%("id":"#{asked.dig('feed', 'id')}")) },
             "the search a scout ran handed back the question it was answering")
    end

    assert(@server.prompts.any? { |prompt| prompt.include?("search the web") }, "the lead is told scouts can search the web")
    assert(@server.prompts.any? { |prompt| prompt.include?(%(key "exa")) }, "the scout is told the web search")
  end

  test "an answer is judged by ten judges, and the share who found it answered is its score" do
    scout("Find the Acme invoice's total") { @server.answer("It is $4,200 [feed #{@invoice.id}].") }
    @server.answer("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    7.times { @server.answer_json(answered: true, useful: true, why: "it says so") }
    3.times { @server.answer_json(answered: false, useful: false, why: "it does not") }

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    feed = graphql("query($id: ID!) { feed(id: $id) { analyses { id verified useful } } }", id: asked.dig("feed", "id"))["feed"]

    assert_in_delta 0.7, feed["analyses"].first["verified"]
    assert_in_delta 0.7, feed["analyses"].first["useful"]
  end

  test "what a scout finds worth keeping becomes a note, connected to the question" do
    scout("Note where HN Search is hosted") do
      @server.answer_tool_call("feed", do: "create", type: "uris:note", title: "HN Search is hosted in Canada")
      @server.answer("Kept it.")
    end
    @server.answer("It is hosted in Canada.")

    asked = ask("where is hn search hosted?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      note = Feed.find_by!(title: "HN Search is hosted in Canada")

      assert_equal Feed::NOTE, note.type
      assert_includes Feed.find(asked.dig("feed", "id")).connected.pluck(:id), note.id
    end
  end

  test "a scout changes only what the run made, whatever a page tells it to do" do
    scout("Tidy the catalog") do
      @server.answer_tool_call("feed", do: "note", id: @invoice.id.to_s, note: "wiped")
      @server.answer_tool_call("search", query: "invoice")
      @server.answer_tool_call("feed", do: "rename", id: @invoice.id.to_s, title: "wiped")
      @server.answer_tool_call("connect", a: @invoice.id.to_s, b: @other.id.to_s)
      @server.answer_tool_call("search", query: "invoice")
      @server.answer_tool_call("feed", do: "create", type: "uris:feed", title: "every hour", prompt: "spend")
      @server.answer("I could not.")
    end
    @server.answer("I could not.")

    ask("Connect the invoice to the beach photo")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      @invoice.reload

      assert_nil @invoice.note
      assert_equal "Acme invoice", @invoice.title
      assert_empty @invoice.connected
      assert_not Feed.exists?(title: "every hour")
    end
  end

  test "a scout can keep a page but cannot sync, export or snapshot through anything but the web" do
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "drop", name: "Drop") }
    scout("Keep example.com") do
      @server.answer_tool_call("resource", do: "sync", key: "drop")
      @server.answer_tool_call("resource", do: "snapshot", key: "drop", input: { url: "https://example.com" })
      @server.answer("I could not.")
    end
    @server.answer("I could not.")

    asked = ask("keep example.com")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      logs = Analysis.find(asked.dig("analysis", "id")).logs

      assert_match(/\[x\].*resource.*sync/, logs)
      assert_match(/\[x\].*resource.*snapshot.*does not keep pages/, logs)
      assert_equal 0, Run.where(resource: @storage).count
    end
  end

  test "a question with no model to answer it fails with the reason" do
    Tenant.switch(@tenant) { Resource.destroy_all }

    asked = ask("anything?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal "failed", analysis.status
      assert_match(/agent role/, analysis.error)
    end
  end

  test "an empty question is refused" do
    body = post_ask("   ")

    assert_match(/needs something in it/, body.dig("errors", 0, "message"))
  end

  private

    def scout(task)
      @server.answer_tool_call("scout", task: task)
      yield
    end

    def ask(question)
      post_ask(question).dig("data", "askCatalog")
    end

    def follow_up(id, question)
      execute(FOLLOW_UP, id: id, question: question).dig("data", "askCatalog")
    end

    def post_ask(question)
      execute(ASK, question: question)
    end

    def graphql(query, **variables)
      execute(query, **variables)["data"]
    end

    def execute(query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.uris.test/mcp")

      post "/graphql",
           params: { query: query, variables: variables.to_json },
           headers: { "HOST" => "#{@tenant.subdomain}.uris.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
