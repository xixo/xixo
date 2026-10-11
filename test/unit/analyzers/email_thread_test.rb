require "test_helper"

class EmailThreadTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "thread-#{SecureRandom.hex(4)}", name: "Threads")
    Tenant.switch(@tenant) do
      @shared = Resource::Database.create!(key: "mail", name: "Mail")
      @adas = Resource::Database.create!(key: "adas-mail", name: "Ada's mail", owner_subject: "ada")
    end
  end

  test "a reply keeps what it says apart from what it quotes" do
    said = Quoted.split(<<~TEXT)
      Thursday works. I'll bring the ladder.

      On Tue, Mar 17, 2026 at 9:30 AM Bea Okonkwo <bea@example.invalid>
      wrote:
      > Can you do Thursday for the roof?
      > The felt has lifted again.
    TEXT

    assert_equal "Thursday works. I'll bring the ladder.", said.fresh
    assert said.earlier.start_with?("On Tue, Mar 17, 2026 at 9:30 AM Bea Okonkwo")
    assert said.earlier.end_with?("Can you do Thursday for the roof?\nThe felt has lifted again.")
  end

  test "an Outlook reply's header block starts what it quotes" do
    said = Quoted.split("Approved.\n\nFrom: Priya Raman\nSent: Monday, March 16, 2026 4:02 PM\nTo: Ash\nSubject: Quote\n\nThe quote is $4,200.")

    assert_equal "Approved.", said.fresh
    assert_match(/The quote is \$4,200/, said.earlier)
  end

  test "a message with nothing quoted, or nothing but a quote, is all its own" do
    assert_nil Quoted.split("Just a note.\n\nThanks").earlier
    assert_nil Quoted.split("> only a quote\n> and more").earlier
  end

  test "an email's quoted history is its own section, and the summary reads only the new text" do
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
      Analyzer.for(feed.reload, analysis: analysis).analyze
      analysis.finished!
      feed.reload
    end

    def grant(subject)
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
    end
end
