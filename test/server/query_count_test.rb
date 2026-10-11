require "test_helper"

class QueryCountTest < ActiveSupport::TestCase
  ROW = "id type key title mime summary thumbnailUrl staged analyzedAt createdAt parent { id }".freeze

  setup do
    SearchIndex.reset!
  end

  test "a catalog page costs the same queries however many rows it holds" do
    few = counted(2) { "{ feeds(types: [\"#{Feed::FILE}\"]) { nodes { #{ROW} } } }" }
    many = counted(12) { "{ feeds(types: [\"#{Feed::FILE}\"]) { nodes { #{ROW} } } }" }

    assert_equal few, many
  end

  test "an item's page costs the same queries however many tags it has" do
    few = counted(2, tagged: true) { |item| "{ feed(id: \"#{item.id}\") { #{ROW} tags { #{ROW} } children { #{ROW} } } }" }
    many = counted(12, tagged: true) { |item| "{ feed(id: \"#{item.id}\") { #{ROW} tags { #{ROW} } children { #{ROW} } } }" }

    assert_equal few, many
  end

  private

    def counted(rows, tagged: false)
      tenant = Tenant.create!(subdomain: "counted-#{SecureRandom.hex(4)}", name: "Counted")
      grant = Grant.new(tenant: tenant, claims: Masks::Client::Claims.new("sub" => "ada", "scope" => Grant::SCOPES.join(" ")))

      item = Tenant.switch(tenant) do
        held = Array.new(rows) { |index| create_feed(mime: "text/plain", locator_key: "#{index}.txt").tap { |feed| analyze(feed) } }
        held.drop(1).each { |tag| held.first.connect!(Feed.create!(type: Feed::TAG, key: "tag #{tag.id}")) } if tagged
        held.first
      end

      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(SET|RESET|SELECT set_config)/) }

      Tenant.switch(tenant) do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          result = XixoSchema.execute(yield(item), context: { tenant: tenant, tenant_id: tenant.id, grant: grant })
          assert_nil result["errors"]
        end
      end

      count
    end

    def analyze(feed)
      Analysis.open!(feed: feed, cause: "manual").finished!
    end
end
