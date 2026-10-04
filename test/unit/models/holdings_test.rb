require "test_helper"

class HoldingsTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "hold-#{SecureRandom.hex(4)}", name: "Holdings")
  end

  test "the catalog is counted by kind of file, so photos are counted whatever their format" do
    Tenant.switch(@tenant) do
      storage = Resource::Database.create!(key: "drop", name: "Drop")
      { "beach.jpg" => "image/jpeg", "dog.heic" => "image/heic", "memo.m4a" => "audio/mp4", "lease.pdf" => "application/pdf" }
        .each do |name, mime|
          feed = Feed.create!(type: Feed::FILE, key: name, title: name)
          Reference.record!(feed: feed, resource: storage, locator_key: name, mime: mime, locator: { "key" => name })
        end

      said = Holdings.said

      assert_includes said, "It holds 4 files."
      assert_includes said, "By kind, the files are image (2), "
      assert_includes said, "audio (1)"
    end
  end
end
