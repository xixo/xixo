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
    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "ask-#{SecureRandom.hex(4)}", name: "Ask")

    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b" } }
      )
      @invoice = Feed.create!(type: Feed::NOTE, key: "Acme invoice", title: "Acme invoice",
                              note: "Acme invoice 0042 for $4,200, due on 1 October.")
      @other = Feed.create!(type: Feed::NOTE, key: "Beach photo", title: "Beach photo", note: "A beach at dusk.")
    end

    connect!(@tenant)
    SearchIndex.refresh!
  end

  teardown { ENV.delete("XIXO_INFERENCE_ORIGINS") }

  test "a question is kept as a note, answered in one call from what the catalog holds, and connected to what it cites" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal Feed::NOTE, note.type
      assert_equal "feed", note.origin
      assert_equal "done", analysis.status
      assert_match(/\$4,200/, analysis.step_result("text"))
      assert_equal [ @invoice.id ], note.connected.pluck(:id)
    end

    assert_equal 1, @server.prompts.count { |prompt| prompt.include?("Answer from the parts above alone") }

    asked_with = @server.prompts.find { |prompt| prompt.include?("How much is the Acme invoice?") }
    assert_includes asked_with, "[feed #{@invoice.id}] Acme invoice, read in full:\n--- Note ---\nAcme invoice 0042 for $4,200"
  end

  test "beyond what it reads in full, an answer sees what else the search found, by summary" do
    Tenant.switch(@tenant) do
      6.times do |index|
        Feed.create!(type: Feed::NOTE, key: "Invoice #{index}", title: "Invoice #{index}", note: "An invoice.").tap do |feed|
          Analysis.create!(feed: feed, cause: "manual", status: "done", finished_at: Time.current,
                           steps: { "summary" => { "result" => { "summary" => "Invoice #{index} from a plumber, for $#{index}00." } } })
          SearchIndex.index(feed)
        end
      end
    end
    SearchIndex.refresh!
    answers("Seven invoices mention money [feed #{@invoice.id}].")

    ask("Which invoice mentions money?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    asked_with = @server.prompts.find { |prompt| prompt.include?("Which invoice mentions money?") }
    assert_includes asked_with, "Other items the search found, known only by a model's summary of each:"
    assert_match(/- \[feed \d+\] Invoice \d: Invoice \d from a plumber, for \$\d00\./, asked_with)
    assert_operator asked_with.scan(", read in full").size, :<=, Evidence::FEEDS
  end

  test "a question is answered without thinking unless the backend asks for an effort" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "none", @server.efforts.first

    Tenant.switch(@tenant) do
      held = Resource::OpenaiCompatible.find_by!(key: "ollama")
      held.update!(details: held.details.merge("ask_effort" => "model"))
    end
    @server.reset!.serves("qwen3:8b")
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    ask("What is the Acme invoice for?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_nil @server.efforts.first, "as the model likes sends no effort at all"
  end

  ABOUT = <<~GQL.freeze
    mutation($question: String!, $about: ID) {
      askCatalog(input: { question: $question, aboutId: $about }) { feed { id } analysis { id } }
    }
  GQL

  test "a question about an item is connected to it, and reads it first" do
    answers("It is due on 1 October [feed #{@invoice.id}].")
    asked = execute(ABOUT, question: "When is it due?", about: @invoice.id.to_s).dig("data", "askCatalog")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))

      assert_equal @invoice, Analysis.find(asked.dig("analysis", "id")).about
      assert_includes note.connected, @invoice

      later = Analysis.create!(feed: note, cause: "ask", question: "and who sent it?", steps: {})
      assert_equal [ @invoice ], Asking.new(note, analysis: later).first, "a follow-up keeps what it is about"
    end

    assert_includes @server.prompts.find { |prompt| prompt.include?("When is it due?") }, "[feed #{@invoice.id}] Acme invoice"
  end

  test "a question asked on an item's page is told that this and it mean that item" do
    answers("It is due on 1 October [feed #{@invoice.id}].")
    execute(ABOUT, question: "When is this due?", about: @invoice.id.to_s)
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    asked = @server.prompts.find { |prompt| prompt.include?("When is this due?") }

    assert_includes asked, "The question was asked on the page of [feed #{@invoice.id}] Acme invoice, so \"this\""
    assert_includes asked, "When the parts bear on only part of the\nquestion, say what they do show and what they do not"
  end

  test "a question asked from the catalog is told of no page" do
    answers("Nothing matched.")
    execute(ASK, question: "What is due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_not_includes @server.prompts.find { |prompt| prompt.include?("What is due?") }, "asked on the page of"
  end

  test "a question about an item that is not there is refused" do
    body = execute(ABOUT, question: "When is it due?", about: "999999")

    assert_match(/no feed with id 999999/, body.dig("errors", 0, "message"))
  end

  test "a follow-up is asked in the same note, told what was asked before, and the whole conversation is rolled up" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    answers("It is due on 1 October [feed #{@invoice.id}].")
    followed = follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal first.dig("feed", "id"), followed.dig("feed", "id"), "the follow-up stays in the note it follows"

    told = @server.prompts.reverse.find { |prompt| prompt.include?("When is it due?") && prompt.include?("Earlier in this conversation") }
    assert told, "the follow-up is told the conversation so far"
    assert_match(/Asked: How much is the Acme invoice\?\nAnswered: The Acme invoice is for \$4,200/, told)
    assert_includes told, "[feed #{@invoice.id}] Acme invoice", "and reads first what the earlier answer drew on"

    passes = graphql("query($id: ID) { feed(id: $id) { analyses { cause question said drewOn { id } } } }",
                     id: first.dig("feed", "id")).dig("feed", "analyses").select { |pass| pass["cause"] == "ask" }.reverse

    assert_equal [ "How much is the Acme invoice?", "When is it due?" ], passes.pluck("question")
    assert_equal "It is due on 1 October [feed #{@invoice.id}].", passes.last["said"]
    assert_equal [ [ @invoice.id.to_s ], [ @invoice.id.to_s ] ], passes.map { |pass| pass["drewOn"].pluck("id") }

    Tenant.switch(@tenant) do
      rolled = Analysis.find(followed.dig("analysis", "id")).step_result("conversation")

      assert_match(/Asked: How much is the Acme invoice\?.*\$4,200.*Asked: When is it due\?\nAnswered: It is due on 1 October/m, rolled)
      assert_equal [ @invoice.id ], Feed.find(first.dig("feed", "id")).connected.pluck(:id)
    end
  end

  test "once the reply lands the note is catalogued again from the whole conversation" do
    models("agent" => "qwen3:8b", "smart" => "qwen3:8b")

    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    @server.answer_json(title: "Acme invoice")
    @server.answer_json(summary: "Asked what the Acme invoice costs: $4,200.", entities: [ "Acme" ], tags: [ "Acme invoice" ])
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    answers("It is due on 1 October [feed #{@invoice.id}].")
    @server.answer_json(summary: "The Acme invoice is $4,200, due on 1 October.", entities: [ "Acme" ],
                        tags: [ "Acme invoice", "due date" ])
    follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    summarised = @server.prompts.reverse.find { |prompt| prompt.include?("Catalogue the conversation") }
    assert_match(/Asked: How much is the Acme invoice\?.*Asked: When is it due\?/m, summarised)

    note = graphql("query($id: ID) { feed(id: $id) { summary tags { key } } }", id: first.dig("feed", "id"))["feed"]

    assert_equal "The Acme invoice is $4,200, due on 1 October.", note["summary"]
    assert_includes note["tags"].pluck("key"), "due date"
  end

  test "the answer is shown before the note is titled and the conversation rolled up" do
    models("agent" => "qwen3:8b", "fast" => "qwen3:8b")
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    @server.answer_json(title: "Acme invoice total: $4,200, please and thank you")

    asked = ask("How much is the Acme invoice?")

    assert_nil asked.dig("feed", "title"), "a question is not its own title"

    perform_enqueued_jobs(only: AnalyzeFeedJob)

    answered = @server.prompts.index { |prompt| prompt.include?("Answer from the parts above alone") }
    titled = @server.prompts.index { |prompt| prompt.include?("Title the note") }
    assert_operator answered, :<, titled
    assert_match(/Asked: How much is the Acme invoice\?\s+Answered: The Acme invoice is for \$4,200/, @server.prompts[titled])

    Tenant.switch(@tenant) do
      note = Feed.find(asked.dig("feed", "id"))
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal "Acme invoice total: $4,200, please and thank you", note.title
      assert_equal "How much is the Acme invoice?", note.key
      assert_operator analysis.finished_at, :<=, analysis.steps.dig("conversation", "finished_at").then { |at| Time.iso8601(at) }
    end
  end

  test "a title never carries the feed an answer cited" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    @server.answer_json(title: "Acme invoice: $4,200, based on feed #{@invoice.id}")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) { assert_equal "Acme invoice: $4,200", Feed.find(asked.dig("feed", "id")).title }
  end

  test "with no fast model the note is titled by the slower model" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    @server.answer_json(title: "Acme invoice total")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

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
    answers("$4,200 [feed #{@invoice.id}].")
    first = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)
    answers("1 October [feed #{@invoice.id}].")
    follow_up(first.dig("feed", "id"), "When is it due?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    again = graphql("mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id } } }", id: first.dig("feed", "id"))

    Tenant.switch(@tenant) { assert_equal "When is it due?", Analysis.find(again.dig("analyzeFeed", "analysis", "id")).question }
  end

  test "a total over a table's rows is worked out by code, and the model answers with the figure" do
    ledger = Tenant.switch(@tenant) do
      Feed.create!(type: Feed::FILE, key: "ledger.csv", title: "ledger.csv").tap do |feed|
        rows = [ %w[Date Payee Amount], [ "2026-08-02", "Fernwood Grocers", "-40.10" ],
                 [ "2026-08-19", "Fernwood Grocers", "-60.25" ], [ "2026-09-01", "Fernwood Grocers", "-9.00" ] ]
        Analysis.create!(feed: feed, cause: "manual", status: "done", finished_at: Time.current, steps: {
          "text" => { "result" => rows.map { |row| row.join(",") }.join("\n") },
          "tables" => { "result" => [ Tables.framed("ledger.csv", rows) ] }
        })
      end
    end
    Tenant.switch(@tenant) { SearchIndex.index(ledger) }
    SearchIndex.refresh!

    @server.answer_json(answer: "", world: false,
                        compute: { table: "ledger.csv", op: "sum", column: "Amount",
                                   where: [ [ "Payee", "contains", "Fernwood" ], [ "Date", "starts", "2026-08" ] ] })
    answers("You spent $100.35 at Fernwood Grocers in August [feed #{ledger.id}].")

    asked = ask("How much did I spend at Fernwood Grocers in August, from the ledger?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    computed = @server.prompts.find { |prompt| prompt.include?("it came to") }
    assert_match(/it came to -100\.35 over 2 rows/, computed)
    assert_includes @server.prompts.first, "Tables whose rows can be worked over:\n- [feed #{ledger.id}] ledger.csv: Date, Payee, Amount (3 rows)"
    Tenant.switch(@tenant) do
      assert_equal "You spent $100.35 at Fernwood Grocers in August [feed #{ledger.id}].",
                   Analysis.find(asked.dig("analysis", "id")).step_result("text")
    end
  end

  test "an answer that leaves out the figure worked out for it is sent back once" do
    ledger = Tenant.switch(@tenant) do
      Feed.create!(type: Feed::FILE, key: "ledger.csv", title: "ledger.csv").tap do |feed|
        rows = [ %w[Date Payee Amount], [ "2026-08-02", "Fernwood Grocers", "-40.10" ], [ "2026-08-19", "Fernwood Grocers", "-60.25" ] ]
        Analysis.create!(feed: feed, cause: "manual", status: "done", finished_at: Time.current, steps: {
          "text" => { "result" => rows.map { |row| row.join(",") }.join("\n") },
          "tables" => { "result" => [ Tables.framed("ledger.csv", rows) ] }
        })
      end
    end
    Tenant.switch(@tenant) { SearchIndex.index(ledger) }
    SearchIndex.refresh!

    @server.answer_json(answer: "", world: false, compute: { table: "ledger.csv", op: "count", where: [] })
    answers("You went to Fernwood Grocers on 2026-08-02 [feed #{ledger.id}].")
    answers("You went to Fernwood Grocers 2 times [feed #{ledger.id}].")

    asked = ask("How many times did I shop at Fernwood Grocers, by the ledger?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert(@server.prompts.any? { |prompt| prompt.include?("It leaves out 2, the figure worked out over the table") })
    Tenant.switch(@tenant) do
      assert_equal "You went to Fernwood Grocers 2 times [feed #{ledger.id}].",
                   Analysis.find(asked.dig("analysis", "id")).step_result("text")
    end
  end

  test "an answer with a number found nowhere in what it read is sent back once" do
    answers("The Acme invoice is for $9,999 [feed #{@invoice.id}].")
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert(@server.prompts.any? { |prompt| prompt.include?("It gives 9999, which appear nowhere") })
    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))

      assert_equal "The Acme invoice is for $4,200 [feed #{@invoice.id}].", analysis.step_result("text")
      assert_match(/numbers not in the evidence : 9999/, analysis.logs)
    end
  end

  test "an answered question reads cleanly in the catalog, and asking it again asks rather than analyzes" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")

    asked = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    note = graphql("query($id: ID) { feed(id: $id) { asked summary analyzedAt } }", id: asked.dig("feed", "id"))["feed"]

    assert note["asked"]
    assert_equal "The Acme invoice is for $4,200.", note["summary"]
    assert note["analyzedAt"].present?

    again = graphql("mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id } } }", id: asked.dig("feed", "id"))

    Tenant.switch(@tenant) { assert_equal "ask", Analysis.find(again.dig("analyzeFeed", "analysis", "id")).cause }
  end

  test "neither the question nor an earlier answer is ever read as a source" do
    answers("The Acme invoice is for $4,200 [feed #{@invoice.id}].")
    earlier = ask("How much is the Acme invoice?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)
    SearchIndex.refresh!

    answers("It is $4,200 [feed #{@invoice.id}].")
    ask("What is the Acme invoice for?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_not_includes @server.prompts.last(2).join, "[feed #{earlier.dig('feed', 'id')}]"
  end

  test "a question about the world goes to an agent with the web, which changes only what the run made" do
    Tenant.switch(@tenant) do
      Resource::Search.create!(key: "exa", details: { "provider" => "exa" }, credentials: { "api_key" => "k" })
    end
    @server.answer_json(answer: "The catalog does not have it.", world: true)
    @server.answer_tool_call("feed", do: "note", id: @invoice.id.to_s, note: "wiped")
    @server.answer_tool_call("feed", do: "rename", id: @invoice.id.to_s, title: "wiped")
    @server.answer("It is 14°C and raining in Vancouver.")

    asked = ask("What is the weather in Vancouver?")
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      analysis = Analysis.find(asked.dig("analysis", "id"))
      @invoice.reload

      assert_equal "It is 14°C and raining in Vancouver.", analysis.step_result("text")
      assert_equal "Acme invoice 0042 for $4,200, due on 1 October.", @invoice.note
      assert_equal "Acme invoice", @invoice.title
    end
    assert(@server.prompts.any? { |prompt| prompt.include?(%(key "exa")) }, "the agent is told the web search")
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

    def answers(said)
      @server.answer_json(answer: said, world: false)
    end

    def models(declared)
      Tenant.switch(@tenant) do
        Resource::OpenaiCompatible.find_by!(key: "ollama").update!(details: { "base_url" => @server.base_url, "models" => declared })
      end
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
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

      post "/graphql",
           params: { query: query, variables: variables.to_json },
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
