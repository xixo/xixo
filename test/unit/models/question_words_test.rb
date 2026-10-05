require "test_helper"

class QuestionWordsTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!
    @tenant = Tenant.create!(subdomain: "words-#{SecureRandom.hex(4)}", name: "Words")
  end

  def indexed(feed)
    SearchIndex.index(feed)
    feed
  end

  test "the words a question is asked in do not count as matching it" do
    requires_search_engine!

    Tenant.switch(@tenant) do
      lease = indexed(create_feed(key: "lease.md", title: "lease.md"))
      SearchIndex.client.index(index: SearchIndex.alias_name, id: lease.id,
                               body: SearchIndex.document(lease).merge(body: "When is the rent due? It is the first."))
      dentist = indexed(create_feed(key: "dentist.ics", title: "dentist.ics"))
      SearchIndex.client.index(index: SearchIndex.alias_name, id: dentist.id,
                               body: SearchIndex.document(dentist).merge(summary: "A dentist cleaning appointment."))
      SearchIndex.refresh!

      found = SearchIndex.lexical("when is the dentist appointment", tenant: @tenant, limit: 50, from: 0)[:ids]

      assert_equal [ dentist.id ], found
    end
  end

  test "a listing with no query is newest first and says how many there are" do
    Tenant.switch(@tenant) do
      older = indexed(create_feed(key: "older.txt"))
      older.update_columns(created_at: 2.days.ago)
      indexed(older.reload)
      newer = indexed(create_feed(key: "newer.txt"))
      SearchIndex.refresh!

      page = SearchIndex.page(nil, tenant: @tenant, type: Feed::FILE, limit: 1)

      assert_equal [ newer.id ], page[:ids]
      assert_equal 2, page[:total]
    end
  end
end
