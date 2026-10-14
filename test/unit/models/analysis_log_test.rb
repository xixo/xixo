require "test_helper"

class AnalysisLogTest < ActiveSupport::TestCase
  test "the same line logged twice in one job is kept twice" do
    tenant = Tenant.create!(subdomain: "log-#{SecureRandom.hex(4)}", name: "Log")

    Tenant.switch(tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "notes.txt", title: "notes.txt")
      analysis = Analysis.open!(feed: feed, cause: "manual")

      Analysis.cache do
        2.times { analysis.log_skip("parked", "no answer", "laptop is asleep") }
      end

      assert_equal 2, analysis.reload.logs.scan("laptop is asleep").size
      assert_equal 2, analysis.lines
    end
  end
end
