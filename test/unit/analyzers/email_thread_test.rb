require "test_helper"

class EmailThreadTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "thread-#{SecureRandom.hex(4)}", name: "Threads")
    Tenant.switch(@tenant) do
      @shared = Resource::Database.create!(key: "mail", name: "Mail")
      @adas = Resource::Database.create!(key: "adas-mail", name: "Ada's mail", owner_subject: "ada")
    end
  end

  test "an email's quoted history stays out of its summary, which reads only the new text" do
    text = "From: ash@example.invalid\n\nThursday works.\n\n## Earlier in the thread\n\nOn Tue, Mar 17, 2026, Bea wrote:\n> Can you do Thursday?"
    FakeAgent.script = lambda do |*|
      FakeAgent.extracted({ "headers" => { "from" => "ash@example.invalid", "subject" => "Roof" }, "text" => text,
                            "outline" => [ { "name" => "Message from ash@example.invalid", "from" => 0 },
                                           { "name" => "Earlier in the thread", "from" => text.index("## Earlier") } ],
                            "thread" => { "ids" => %w[r2@example.invalid r1@example.invalid] } }, extractor: "email")
    end

    Tenant.switch(@tenant) do
      reply = email(@shared, "reply.eml", id: "r2@example.invalid", in_reply_to: "r1@example.invalid",
                                          body: "Thursday works.\n\nOn Tue, Mar 17, 2026, Bea wrote:\n> Can you do Thursday?")
      analysis = reply.analysis
      text = analysis.step_result("text")
      outline = analysis.step_result("outline")
      prompt = Analyzer.for(reply, analysis: analysis).summary_prompt

      assert_equal [ "Message from ash@example.invalid", "Earlier in the thread" ], outline.pluck("name")
      assert text[outline.last["from"]..].start_with?("## Earlier in the thread")
      assert_match(/Thursday works/, prompt)
      assert_no_match(/Can you do Thursday/, prompt)
      assert_equal %w[r2@example.invalid r1@example.invalid], analysis.step_result("thread")["ids"]
    end
  end

  test "a thread lists its messages oldest first, leaving out one the reader cannot read" do
    Tenant.switch(@tenant) do
      first = email(@shared, "1.eml", id: "t1@example.invalid", date: "Mon, 16 Mar 2026 09:00:00 +0000", body: "Can you do Thursday?")
      second = email(@shared, "2.eml", id: "t2@example.invalid", in_reply_to: "t1@example.invalid",
                                       date: "Tue, 17 Mar 2026 09:00:00 +0000", body: "Thursday works.")
      private_reply = email(@adas, "3.eml", id: "t3@example.invalid", in_reply_to: "t2@example.invalid",
                                            references: "<t1@example.invalid> <t2@example.invalid>",
                                            date: "Wed, 18 Mar 2026 09:00:00 +0000", body: "Bring the ladder.")
      unrelated = email(@shared, "4.eml", id: "u1@example.invalid", body: "Something else.")

      assert_equal [ first, second, private_reply ], private_reply.in_thread(grant("ada"))
      assert_equal [ first, second ], second.in_thread(grant("bob"))
      assert_empty unrelated.in_thread(grant("bob"))
    end
  end

  private

    def email(resource, key, id:, body:, in_reply_to: nil, references: nil, date: "Tue, 17 Mar 2026 10:00:00 +0000")
      raw = [
        "From: ash@example.invalid", "To: bea@example.invalid", "Subject: Roof", "Date: #{date}",
        "Message-ID: <#{id}>", ("In-Reply-To: <#{in_reply_to}>" if in_reply_to), ("References: #{references}" if references),
        "", body
      ].compact.join("\r\n")
      resource.upload(key, raw)
      feed = Feed.create!(type: Feed::FILE, key: key, title: key)
      Reference.record!(feed: feed, resource: resource, locator_key: key, locator: { "key" => key }, mime: "message/rfc822")
      analysis = Analysis.open!(feed: feed, cause: "manual")
      Analyzer.for(feed.reload, analysis: analysis).extract!
      analysis.finished!
      feed.reload
    end

    def grant(subject)
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
    end
end
