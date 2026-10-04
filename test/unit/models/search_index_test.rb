require "test_helper"

class SearchIndexTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @demo = Tenant.create!(subdomain: "demo-#{SecureRandom.hex(4)}", name: "Demo items")
    @acme = Tenant.create!(subdomain: "acme-#{SecureRandom.hex(4)}", name: "Acme")

    Tenant.switch(@demo) do
      create_feed(mime: "application/pdf", title: "March invoice", locator_key: "invoices/march.pdf")
      create_feed(mime: "image/jpeg", title: "Beach photo", locator_key: "photos/beach.jpg")
      create_feed(mime: "application/pdf", title: "file-1.pdf", locator_key: "docs/file-1.pdf")
      create_feed(mime: "application/pdf", title: "file-2.pdf", locator_key: "docs/file-2.pdf")
    end

    Tenant.switch(@acme) do
      create_feed(mime: "application/pdf", title: "Acme invoice", locator_key: "invoices/acme.pdf")
    end

    SearchIndex.refresh!
  end

  test "a word finds the other forms of it, as a plural finds the singular" do
    skip "stemming is the search engine's; set URIS_TEST_SEARCH_ENGINE to run it" if SEARCH_ENGINE_URL.nil?

    Tenant.switch(@demo) do
      assert_equal [ "March invoice" ], Feed.search("invoices").pluck(:title)
    end
  end

  test "search finds items by title" do
    Tenant.switch(@demo) do
      assert_equal [ "March invoice" ], Feed.search("March").pluck(:title)
    end
  end

  test "the last word is matched as it begins, so a search typed a letter at a time finds as it goes" do
    Tenant.switch(@demo) do
      assert_equal [ "March invoice" ], Feed.search("Marc").pluck(:title)
      assert_equal [ "March invoice" ], Feed.search("march inv").pluck(:title)
      assert_empty Feed.search("arch invoice").pluck(:title), "only the last word is taken as unfinished"
    end
  end

  test "search finds items by locator" do
    requires_search_engine!

    Tenant.switch(@demo) do
      assert_equal [ "Beach photo" ], Feed.search("beach").pluck(:title)
    end
  end

  test "a search never crosses tenants, even for a shared term" do
    requires_search_engine!

    Tenant.switch(@demo) do
      assert_equal [ "March invoice" ], Feed.search("invoice").pluck(:title)
    end

    Tenant.switch(@acme) do
      assert_equal [ "Acme invoice" ], Feed.search("invoice").pluck(:title)
    end
  end

  test "the tenant filter is on the alias, so the engine applies it" do
    requires_search_engine!

    hits = SearchIndex.client.search(
      index: SearchIndex.alias_for(@demo),
      body: { query: { match_all: {} } }
    ).dig("hits", "hits")

    assert_equal [ @demo.id ], hits.map { |h| h.dig("_source", "tenant_id") }.uniq
  end

  test "digits in a path are searchable and distinguish siblings" do
    requires_search_engine!

    Tenant.switch(@demo) do
      assert_equal [ "file-1.pdf" ], Feed.search("file-1").pluck(:title)
    end
  end

  test "a question worded as a sentence still finds what most of its words name" do
    Tenant.switch(@demo) do
      create_feed(mime: "application/pdf", title: "Roof inspection invoice")
      SearchIndex.refresh!

      assert_equal 1, SearchIndex.lexical("roof inspection cost", tenant: @demo, limit: 10, from: 0)[:total]
      assert_equal 0, SearchIndex.lexical("roof cost", tenant: @demo, limit: 10, from: 0)[:total],
                   "two words are a phrase to match exactly, not a sentence to loosen"
    end
  end

  test "kind narrows results" do
    Tenant.switch(@demo) do
      assert_equal [ "Beach photo" ], Feed.search(nil, mime: "image/jpeg").pluck(:title)
    end
  end

  test "searching with no tenant in scope raises rather than returning everything" do
    assert_raises(ArgumentError) { SearchIndex.search("invoice", tenant: nil) }
  end

  test "a page of matches says how many there are, not merely how many it handed back" do
    Tenant.switch(@demo) do
      first = Feed.found(nil, mime: "application/pdf", limit: 2)

      assert_equal 2, first.nodes.length
      assert_equal 3, first.total, "three pdfs match, and a short page must not hide the third"
      assert first.has_more
      assert_equal "2", first.next_cursor

      second = Feed.found(nil, mime: "application/pdf", limit: 2, from: first.next_cursor.to_i)

      assert_equal 1, second.nodes.length
      assert_equal 3, second.total
      assert_not second.has_more
      assert_nil second.next_cursor

      walked = (first.nodes + second.nodes).map(&:id)

      assert_equal walked, walked.uniq, "a second page must not repeat the first"
    end
  end

  test "a page past the end is empty rather than an error" do
    Tenant.switch(@demo) do
      past = Feed.found(nil, from: 500)

      assert_empty past.nodes
      assert_not past.has_more
    end
  end

  test "a destroyed item leaves the index" do
    Tenant.switch(@demo) do
      Feed.find_by!(title: "March invoice").destroy!
      SearchIndex.refresh!

      assert_equal [], Feed.search("March").pluck(:title)
    end
  end

  test "a page is indexed in one request rather than one per document" do
    items = Tenant.switch(@demo) do
      Array.new(3) { |n| Feed.create!(type: Feed::FILE, key: "bulk #{n}", title: "bulk #{n}") }
    end

    calls = []

    SearchIndex.client.define_singleton_method(:bulk) { |**args| calls << args; { "items" => [] } }

    begin
      assert_equal 3, SearchIndex.index_all(items)
    ensure
      SearchIndex.client.singleton_class.remove_method(:bulk)
    end

    assert_equal 1, calls.length, "three documents must not cost three requests"
    assert_equal 6, calls.first[:body].length, "an action line and a document for each"
  end

  test "documents written in bulk are the ones that come back" do
    items = Tenant.switch(@demo) do
      Array.new(3) { |n| Feed.create!(type: Feed::FILE, key: "bulked-#{n}", title: "bulked-#{n}") }
    end

    assert_equal 3, SearchIndex.index_all(items)

    SearchIndex.refresh!

    Tenant.switch(@demo) do
      assert_equal items.map(&:id).sort, SearchIndex.search("bulked").sort
    end
  end

  test "a bulk write the engine refused raises rather than reporting success" do
    item = Tenant.switch(@demo) { Feed.create!(type: Feed::FILE, key: "refused", title: "refused") }
    refusal = { "items" => [ { "index" => { "error" => { "reason" => "mapper_parsing_exception" } } } ] }

    SearchIndex.client.define_singleton_method(:bulk) { |**| refusal }

    begin
      error = assert_raises(SearchIndex::Failed) { SearchIndex.index_all([ item ]) }

      assert_match(/mapper_parsing_exception/, error.message)
    ensure
      SearchIndex.client.singleton_class.remove_method(:bulk)
    end
  end

  test "indexing nothing asks the engine nothing" do
    SearchIndex.client.define_singleton_method(:bulk) { |**| raise "bulk should not be called" }

    begin
      assert_equal 0, SearchIndex.index_all([])
    ensure
      SearchIndex.client.singleton_class.remove_method(:bulk)
    end
  end
end
