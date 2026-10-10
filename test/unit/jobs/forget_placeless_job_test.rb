require "test_helper"

class ForgetPlacelessJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "placeless-#{SecureRandom.hex(4)}", name: "Placeless")
  end

  test "of the feeds it is handed, only those left with no place and nothing someone gave them are forgotten" do
    held = Tenant.switch(@tenant) do
      bare = Feed.create!(type: Feed::FILE, key: "bare.txt", title: "bare.txt")
      noted = Feed.create!(type: Feed::FILE, key: "noted.txt", note: "kept for a reason")
      placed = create_feed(key: "placed.txt", locator_key: "placed.txt")
      minted = Feed.create!(type: Feed::FILE, key: "minted.txt", origin: "feed")
      [ bare, noted, placed, minted ]
    end

    Tenant.switch(@tenant) { ForgetPlacelessJob.perform_now(held.first(3).map(&:id), "photos") }

    Tenant.switch(@tenant) do
      assert_equal %w[minted.txt noted.txt placed.txt], Feed.files.order(:key).pluck(:key)
      assert_equal "forgot bare.txt, whose last place went with photos", AuditEvent.find_by!(action: "forget_placeless_feed").told
    end
  end
end
