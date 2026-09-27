require "test_helper"

class DigestReferencesJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "dig-#{SecureRandom.hex(4)}", name: "Digests")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "drop", name: "Drop")
      @storage.upload("notes.txt", "remember the milk")
      @storage.upload("bigger.txt", "remember the eggs")

      @notes = reference("notes.txt")
      @bigger = reference("bigger.txt")
    end
  end

  test "a reference with no fingerprint is given the SHA-256 of its bytes" do
    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      assert_equal Digest::SHA256.hexdigest("remember the milk"), @notes.reload.digest
      assert_equal Digest::SHA256.hexdigest("remember the eggs"), @bigger.reload.digest
    end
  end

  test "one whose bytes cannot be read is passed over and does not stop the rest" do
    Tenant.switch(@tenant) { @notes.update_columns(locator: { "key" => "missing.txt" }) }

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) do
      assert_nil @notes.reload.digest
      assert_equal Digest::SHA256.hexdigest("remember the eggs"), @bigger.reload.digest
    end
  end

  test "one already fingerprinted is left alone" do
    Tenant.switch(@tenant) { @notes.update_columns(digest: "kept") }

    DigestReferencesJob.perform_now

    Tenant.switch(@tenant) { assert_equal "kept", @notes.reload.digest }
  end

  private

    def reference(key)
      feed = Feed.create!(type: Feed::FILE, key: key, title: key)

      Reference.record!(feed: feed, resource: @storage, locator_key: key, locator: { "key" => key })
    end
end
