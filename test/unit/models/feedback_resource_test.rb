require "test_helper"

class FeedbackResourceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "fb-#{SecureRandom.hex(4)}", name: "Feedback")
    @listener = Tenant.switch(@tenant) { Resource::Feedback.create!(key: "feedback", name: "Feedback") }
  end

  test "an ask is never answered, and is kept as a note under the feedback tag with what it was for" do
    Tenant.switch(@tenant) do
      asked_about = Feed.create!(type: Feed::NOTE, key: "who is the president of france?")
      Current.set(acting_for: asked_about.id) do
        @answered = @listener.command("ask", question: "who is the president of france today?",
                                             context: "a question about the world", wanted: "a web search")
      end

      kept = Feed.find(@answered[:feedback])

      assert_equal false, @answered[:answered]
      assert_match(/Nothing here can answer that yet/, @answered[:said])
      assert_equal "Wanted: who is the president of france today?", kept.title
      assert_match(/Would have helped: a web search/, kept.note)
      assert_includes kept.connected, Feed.tag!("feedback")
      assert_includes kept.connected, asked_about
      assert_equal [ kept ], Feed.tag!("feedback").connected.to_a
    end
  end

  test "an ask needs a question" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError, match: /requires question/) { @listener.command("ask", context: "nothing") }
      assert_raises(ArgumentError, match: /needs a question/) { @listener.command("ask", question: "  ") }
    end
  end

  test "it serves feedback, and agents are told to use it for what nothing else can do" do
    Tenant.switch(@tenant) do
      assert_equal [ :feedback ], @listener.capabilities
      grant = Feed.create!(type: Feed::NOTE, key: "a question").grant(scopes: Feed::ASKING_SCOPES)

      assert_match(/do=ask, key "feedback"/, Reach.new(grant).told)
      assert_not Reach.new(grant).web?, "feedback alone is not the web"
    end
  end
end
