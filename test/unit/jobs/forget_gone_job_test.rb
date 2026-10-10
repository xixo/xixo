require "test_helper"

class ForgetGoneJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "gone-#{SecureRandom.hex(4)}", name: "Gone")
    @other = Tenant.create!(subdomain: "gone-#{SecureRandom.hex(4)}", name: "Elsewhere")
  end

  def gone(key, tenant: @tenant, since: 31.days.ago)
    Tenant.switch(tenant) do
      create_feed(key: key, locator_key: key).tap do |feed|
        feed.references.update_all(gone_at: since, seen_at: since - 1.day)
      end
    end
  end

  def held?(feed, tenant: @tenant)
    Tenant.switch(tenant) { Feed.exists?(feed.id) }
  end

  test "a feed gone from every place for longer than the grace period is forgotten, in every tenant" do
    mine = gone("deleted.pdf")
    theirs = gone("removed.pdf", tenant: @other)

    ForgetGoneJob.perform_now

    assert_not held?(mine)
    assert_not held?(theirs, tenant: @other)

    Tenant.switch(@tenant) do
      forgotten = AuditEvent.find_by!(action: "forget_gone_feed")

      assert_equal({ "title" => "deleted.pdf", "places" => 1 }, forgotten.arguments)
      assert_equal "forgot deleted.pdf, gone from every place it lived for 30 days", forgotten.told
    end
  end

  test "a feed gone only lately, or still found in one place, stays" do
    lately = gone("lately.pdf", since: 2.days.ago)
    partly = gone("partly.pdf")

    Tenant.switch(@tenant) do
      other = Resource::S3.create!(key: "other", details: { "endpoint" => "http://127.0.0.1:1" },
                                   credentials: { "access_key_id" => "k", "secret_access_key" => "s" })
      partly.references.create!(resource: other, locator_key: "partly.pdf", locator: {})
    end

    ForgetGoneJob.perform_now

    assert held?(lately)
    assert held?(partly)
  end

  test "a feed somebody wrote a note on, gave a lifetime, or filed by hand stays" do
    noted = gone("noted.pdf")
    dated = gone("dated.pdf")
    filed = gone("filed.pdf")

    Tenant.switch(@tenant) do
      noted.update!(note: "the receipt for the stove")
      dated.lasts!("365")
      filed.connect!(Feed.tag!("taxes"))
    end

    ForgetGoneJob.perform_now

    assert held?(noted)
    assert held?(dated)
    assert held?(filed)
  end

  test "what analysis filed it under does not keep it, and goes with it when nothing else holds it" do
    feed = gone("tagged.pdf")

    tag, mime = Tenant.switch(@tenant) do
      feed.tag_with!([ "warranty" ])
      feed.connect!(Feed.mime!("application/pdf"))
      [ Feed.tag_named("warranty"), Feed.mimes.find_by!(key: "application/pdf") ]
    end

    ForgetGoneJob.perform_now

    assert_not held?(feed)
    assert_not held?(tag)
    assert_not held?(mime)
  end

  test "a feed whose analysis is still open is left until it settles" do
    feed = gone("busy.pdf")
    Tenant.switch(@tenant) { Analysis.open!(feed: feed, cause: "sync") }

    ForgetGoneJob.perform_now

    assert held?(feed)
  end

  test "the previews xixo rendered for a forgotten feed are deleted with it" do
    feed = gone("photo.jpg")

    derived = Tenant.switch(@tenant) do
      Resource.internal!(:derived).tap do |store|
        store.upload("#{feed.id}/thumbnail.jpg", "jpeg")
        feed.references.create!(resource: store, role: Reference::THUMBNAIL,
                                locator_key: "#{feed.id}/thumbnail.jpg", locator: { "key" => "#{feed.id}/thumbnail.jpg" })
      end
    end

    ForgetGoneJob.perform_now

    assert_not held?(feed)
    Tenant.switch(@tenant) { assert_equal 0, derived.blobs.count }
  end
end
