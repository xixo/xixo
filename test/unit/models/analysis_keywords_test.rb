require "test_helper"

class AnalysisKeywordsTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "kw-#{SecureRandom.hex(4)}", name: "Keywords")
  end

  test "the file's own name and stray characters read off it are not keywords" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "GIG_1960.NEF", title: "GIG_1960.NEF")
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analysis.write_step!("summary", {
        "result" => {
          "summary" => "A family on a frozen lake.",
          "keywords" => [ "winter", "Black dog", "GIG_1960.NEF" ],
          "entities" => [ "GIG_1960.NEF", "7", "a", "black dog", "D750" ]
        }
      })

      assert_equal [ "winter", "Black dog", "D750" ], analysis.keywords
    end
  end
end
