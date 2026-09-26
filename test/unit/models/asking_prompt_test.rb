require "test_helper"

class AskingPromptTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "asking-#{SecureRandom.hex(4)}", name: "Asking")

    Tenant.switch(@tenant) do
      @question = Feed.create!(type: Feed::NOTE, key: "hn.algolia.com", title: "hn.algolia.com")
      @other = Feed.create!(type: Feed::NOTE, key: "Other", title: "Other")
    end
  end

  def result(name, arguments, content = {}, ok: true)
    Agent::Dispatch::Result.new(name: name, arguments: arguments, content: content.to_json, ok: ok, error: nil)
  end

  def searched(*urls)
    result("resource", { "do" => "search", "key" => "exa" }, { results: urls.map { |url| { url: url } } })
  end

  def fetched(url)
    result("resource", { "do" => "get", "key" => "curl", "input" => { "url" => url } }, { text: "a page" })
  end

  def kept(url, id)
    result("resource", { "do" => "snapshot", "key" => "web", "input" => { "url" => url } }, { url: url, id: id.to_s })
  end

  def exa! = Resource::Search.create!(key: "exa", details: { "provider" => "exa" }, credentials: { "api_key" => "k" })
  def curl! = Resource::Curl.create!(key: "curl", name: "Curl")
  def web! = Resource::Web.create!(key: "web", name: "The web")

  def unfinished(calls) = Asking.new(@question).unfinished(calls)

  test "the lead is told what the catalog is, and what is in it now" do
    Tenant.switch(@tenant) do
      storage = Resource::Database.create!(key: "shelf", name: "Shelf")
      2.times do |index|
        photo = Feed.create!(type: Feed::FILE, key: "photo-#{index}.jpg")
        Reference.record!(feed: photo, resource: storage, locator_key: "photo-#{index}.jpg", locator: {})
        photo.connect!(Feed.tag!("holidays"))
      end

      assert_match(/seldom a news feed/, Asking::LEAD_SYSTEM)

      lead = Asking.new(@question).prompt

      assert_match(/The catalog now: It holds 2 files and 2 notes\./, lead)
      assert_match(%r{image/jpeg \(2\)}, lead)
      assert_match(/holidays \(2\)/, lead)
    end
  end

  test "an empty catalog is said to be empty" do
    Tenant.switch(@tenant) do
      Feed.delete_all

      assert_equal "It is empty.", Holdings.said
    end
  end

  test "a feed cited with a link keeps the citation and loses the link" do
    said = "See [feed 132](https://example.com/feed.xml), [Feed: 7](x) and [HN](https://hn.algolia.com)."

    assert_equal "See [feed 132], [feed 7] and [HN](https://hn.algolia.com).", Asking.new(@question).tidied(said)
  end

  test "with nothing beyond the catalog the question is asked of the catalog alone" do
    Tenant.switch(@tenant) do
      lead = Asking.new(@question).prompt
      briefing = Asking.new(@question).briefing("find what hn.algolia.com is")

      assert_match(/hn\.algolia\.com/, lead)
      assert_match(/Scouts can search the catalog and open what they find and make notes/, lead)
      assert_match(/find what hn\.algolia\.com is.*hn\.algolia\.com/m, briefing)
      assert_no_match(/look beyond it/, briefing)
      assert_nil unfinished([])
    end
  end

  test "the lead is told what its scouts can do, and never the tools themselves" do
    Tenant.switch(@tenant) do
      exa!
      web!
      curl!
      lead = Asking.new(@question).prompt

      assert_match(/search the web, read pages, keep pages as items in the catalog/, lead)
      assert_no_match(/key "exa"|do=snapshot/, lead)
    end
  end

  test "the lead is turned back until it has sent a scout" do
    Tenant.switch(@tenant) do
      assert_match(/not sent a scout/, Asking.new(@question).led([]))
      assert_match(/not sent a scout/, Asking.new(@question).led([ result("scout", { "task" => "x" }, ok: false) ]))
      assert_nil Asking.new(@question).led([ result("scout", { "task" => "x" }, { report: "found" }) ])
    end
  end

  test "reading and keeping are offered only by what the tenant has attached" do
    Tenant.switch(@tenant) do
      exa!
      searching = Asking.new(@question).briefing("find it")

      assert_match(/key "exa"/, searching)
      assert_match(/In your report/, searching)
      assert_no_match(/only a lead/, searching)
      assert_no_match(/snapshot/, searching)

      web!
      keeping = Asking.new(@question).briefing("find it")

      assert_match(/only a lead/, keeping)
      assert_match(/do=snapshot, key "web"/, keeping)
      assert_match(/open it with feed to read/, keeping)

      curl!
      reading = Asking.new(@question).briefing("find it")

      assert_match(/do=get, key "curl"/, reading)
      assert_no_match(/open it with feed to read/, reading)
    end
  end

  test "an answer that found nothing in the catalog and never looked beyond it is sent to the web" do
    looked = result("search", { "query" => "hn" })
    opened = result("feed", { "id" => @other.id.to_s })

    Tenant.switch(@tenant) do
      exa!

      assert_match(/look at the web.*key "exa"/, unfinished([ looked ]))
      assert_nil unfinished([ looked, opened ])
    end
  end

  test "an answer from search results alone is handed the exact call for each address the search found" do
    Tenant.switch(@tenant) do
      exa!

      assert_nil unfinished([ searched("https://hn.algolia.com/about") ])

      curl!
      pushed = unfinished([ searched("https://hn.algolia.com/about", "javascript:alert(1)") ])

      assert_includes pushed, { do: "get", key: "curl", input: { url: "https://hn.algolia.com/about" } }.to_json
      assert_not_includes pushed, "javascript:"
      assert_match(/without reading/, unfinished([ searched, fetched("https://x.test").with(ok: false) ]))
    end
  end

  test "with no way to fetch, the call to read a page is a snapshot" do
    Tenant.switch(@tenant) do
      exa!
      web!

      pushed = unfinished([ searched("https://hn.algolia.com/about") ])

      assert_includes pushed, { do: "snapshot", key: "web", input: { url: "https://hn.algolia.com/about" } }.to_json
    end
  end

  test "pages read and none kept are pushed to be kept, once there is somewhere to keep them" do
    Tenant.switch(@tenant) do
      exa!
      curl!
      calls = [ searched("https://hn.algolia.com/about"), fetched("https://hn.algolia.com/about") ]

      assert_nil unfinished(calls)

      web!

      assert_includes unfinished(calls), { do: "snapshot", key: "web", input: { url: "https://hn.algolia.com/about" } }.to_json
      assert_nil unfinished(calls + [ kept("https://hn.algolia.com/about", @other.id) ])
      assert_nil unfinished(calls + [ result("feed", { "do" => "create", "type" => "uris:note" }, { id: @other.id.to_s }) ])
    end
  end

  test "live data read from an API is not pushed to be kept, since it is stale within the hour" do
    Tenant.switch(@tenant) do
      curl!
      web!
      forecast = "https://api.open-meteo.com/v1/forecast?latitude=43.65&longitude=-79.38&current_weather=true"
      read = result("resource", { "do" => "get", "key" => "curl", "input" => { "url" => forecast } },
                    { status: 200, content_type: "application/json", text: %({"current_weather":{"temperature":19.2}}) })

      assert_nil unfinished([ read ])
      assert_match(/never .*live data — a forecast, a price, a score or\s+an API's answer/m, Asking.new(@question).briefing("check the weather"))
      assert_match(/lasts 30 days.*"lasts": "forever"/m, Asking.new(@question).briefing("check the weather"))
    end
  end

  test "a question about something as it is now asks for the values, not where to find them" do
    Tenant.switch(@tenant) do
      assert_match(/answer\s+is\s+the\s+values\s+themselves.*where\s+they\s+could\s+be\s+looked\s+up\s+is\s+not\s+an\s+answer/m, Asking.new(@question).prompt)
    end
  end

  test "a follow-up about an earlier answer is said again from it, and is not pushed to send a scout for it" do
    Tenant.switch(@tenant) do
      note = Feed.create!(type: Feed::NOTE, key: "Vancouver weather now")
      Analysis.create!(feed: note, cause: "ask", question: "what is the weather in vancouver", status: "done",
                       steps: { "answer" => { "result" => { "said" => "It is 14°C and raining." } } })
      follow = Analysis.create!(feed: note, cause: "ask", question: "can you output in markdown", steps: {})
      asking = Asking.new(note, analysis: follow)

      assert_match(/say\s+it\s+in\s+markdown.*saying\s+that\s+answer\s+again\s+as\s+asked.*with\s+no\s+scout/m, asking.prompt)
      assert_match(/Asked: what is the weather in vancouver\nAnswered: It is 14°C and raining\./, asking.prompt)
      assert_match(/answer it again, now, saying that earlier answer as asked/, asking.led([]))
      assert_match(/It is 14°C and raining\.\n\nThen asked: can you output in markdown/, asking.judged_question)

      assert_equal Asking::UNSCOUTED, Asking.new(@question).led([]), "a first question still sends a scout"
    end
  end

  test "the question is connected to what it cited, opened and kept, and never to itself" do
    Tenant.switch(@tenant) do
      web!
      kept_page = Feed.create!(type: Feed::NOTE, key: "kept", title: "kept")
      made = Feed.create!(type: Feed::NOTE, key: "made", title: "made")
      tag = Feed.tag!("receipts")

      answered = Agent::Answer.new(
        said: "See [feed #{@other.id}] and [feed #{@question.id}] and [feed #{tag.id}].", reason: :answered, turns: 3,
        calls: [ kept("https://hn.algolia.com/", kept_page.id),
                 result("feed", { "do" => "create", "type" => "uris:note" }, { id: made.id.to_s }),
                 kept("https://refused.test/", 999_999).with(ok: false) ]
      )

      assert_equal [ @other.id, kept_page.id, made.id ].sort, Asking.new(@question).connections(answered).pluck(:id).sort
    end
  end
end
