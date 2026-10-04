require "test_helper"

class RebuildSearchIndexJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "rbld-#{SecureRandom.hex(4)}", name: "Rebuild")
    @other = Tenant.create!(subdomain: "othr-#{SecureRandom.hex(4)}", name: "Other")

    Tenant.switch(@tenant) { create_feed(mime: "application/pdf", title: "March invoice", locator_key: "invoices/march.pdf") }
    Tenant.switch(@other) { create_feed(mime: "application/pdf", title: "Acme invoice", locator_key: "invoices/acme.pdf") }

    SearchIndex.refresh!
  end

  def unstamped!
    live = SearchIndex.live_index
    SearchIndex.client.indices.put_mapping(index: live, body: { _meta: { stamp: "older" } })
  end

  def titles(tenant)
    SearchIndex.refresh!
    Tenant.switch(tenant) { Feed.search(nil).pluck(:title).sort }
  end

  test "an index built from today's mapping is not rebuilt" do
    assert_not SearchIndex.stale?

    live = SearchIndex.live_index
    RebuildSearchIndexJob.perform_now

    assert_equal live, SearchIndex.live_index
  end

  test "a mapping the live index predates is rebuilt and promoted" do
    live = SearchIndex.live_index
    unstamped!

    assert SearchIndex.stale?

    RebuildSearchIndexJob.perform_now

    assert_not_equal live, SearchIndex.live_index
    assert_not SearchIndex.stale?
  end

  test "an index that has gone missing is rebuilt from the catalog" do
    SearchIndex.live_indices.each { |name| SearchIndex.client.indices.delete(index: name) }

    assert SearchIndex.stale?

    RebuildSearchIndexJob.perform_now

    assert_not SearchIndex.stale?
    assert_equal [ "March invoice" ], titles(@tenant)
    assert_equal [ "Acme invoice" ], titles(@other)
  end

  test "every tenant's items are carried into the index that replaces the old one" do
    unstamped!

    RebuildSearchIndexJob.perform_now

    assert_equal [ "March invoice" ], titles(@tenant)
    assert_equal [ "Acme invoice" ], titles(@other)
  end

  test "the index the old one was promoted over is dropped, so none is abandoned" do
    live = SearchIndex.live_index
    unstamped!

    RebuildSearchIndexJob.perform_now

    assert_not SearchIndex.client.indices.exists(index: live)
  end

  test "a rebuild the engine refuses leaves nothing half-built behind it" do
    requires_a_refusable_engine!

    unstamped!

    live = SearchIndex.live_index
    before = SearchIndex.client.index_names.sort

    assert_raises(SearchIndex::Failed) do
      SearchIndex.client.refusing_bulk { RebuildSearchIndexJob.perform_now }
    end

    assert_equal live, SearchIndex.live_index
    assert_equal before, SearchIndex.client.index_names.sort
  end

  test "an item written after the swap lands in the index that replaced the old one" do
    unstamped!

    RebuildSearchIndexJob.perform_now

    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "Late invoice", locator_key: "invoices/late.pdf")
    end

    assert_equal [ "Late invoice", "March invoice" ], titles(@tenant)
  end

  test "the rebuild is reached by the schedule, which holds no tenant" do
    assert RebuildSearchIndexJob.across_tenants
  end
end
