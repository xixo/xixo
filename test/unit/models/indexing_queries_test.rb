require "test_helper"

class IndexingQueriesTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "idx-#{SecureRandom.hex(4)}", name: "Indexing")
  end

  def parent_with(children:)
    box = SecureRandom.hex(4)

    Tenant.switch(@tenant) do
      parent = create_feed(mime: "message/rfc822", title: "mail.eml",
                           locator_key: "#{box}/mail.eml")

      children.times do |n|
        child = create_feed(mime: "text/plain", title: "part-#{n}.txt",
                            locator_key: "#{box}/part-#{n}.txt")
        child.update!(parent: parent)
        Analysis.create!(feed: child, cause: "sync", status: "done",
                         steps: { "text" => { "result" => "part #{n}" } })
      end

      parent
    end
  end

  test "reading a family costs the same whether it has two children or twenty" do
    small = parent_with(children: 2)
    large = parent_with(children: 20)

    counts = [ small, large ].map do |parent|
      Tenant.switch(@tenant) do
        held = Feed.for_indexing.find(parent.id)
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }

        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          SearchIndex.document(held)
        end

        count
      end
    end

    assert_equal counts.first, counts.last,
                 "the query count grew with the number of children: #{counts.inspect}"
  end

  def tagged_feeds(count)
    box = SecureRandom.hex(4)

    Tenant.switch(@tenant) do
      Array.new(count) do |n|
        feed = create_feed(mime: "message/rfc822", title: "mail-#{n}.eml", locator_key: "#{box}/mail-#{n}.eml")
        child = create_feed(mime: "text/plain", title: "part-#{n}.txt", locator_key: "#{box}/part-#{n}.txt")
        child.update!(parent: feed)
        feed.connect!(Feed.tag!("letters"))
        child.connect!(Feed.tag!("tenant #{n}"))
        feed
      end
    end
  end

  test "reading the tags of many feeds costs the same whether there are two or twenty" do
    small = tagged_feeds(2)
    large = tagged_feeds(20)

    counts, documents = [ small, large ].map { |feeds|
      Tenant.switch(@tenant) do
        held = Feed.for_indexing.where(id: feeds.map(&:id)).order(:id).to_a
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }

        said = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          SearchIndex.documents(held)
        end

        [ count, said ]
      end
    }.transpose

    assert_equal counts.first, counts.last,
                 "the query count grew with the number of feeds: #{counts.inspect}"
    assert_equal [ "letters", "tenant 0" ], documents.last.first[:tags]
    assert_equal [ "letters", "tenant 19" ], documents.last.last[:tags]
    assert_equal Tenant.switch(@tenant) { large.last.reload.family_tags }, documents.last.last[:tags]
  end
end
