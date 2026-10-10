require "test_helper"

class CalendarTest < ActiveSupport::TestCase
  test "a calendar's dates are written the way a person reads them" do
    assert_equal "Tuesday, November 3, 2026, 14:15", Analyzer::Calendar.read_as("20261103T141500")
    assert_equal "Sunday, August 30, 2026, 08:00 UTC", Analyzer::Calendar.read_as("20260830T080000Z")
    assert_equal "Tuesday, September 1, 2026", Analyzer::Calendar.read_as("20260901")
    assert_equal "soon", Analyzer::Calendar.read_as("soon")
    assert_equal "20261399", Analyzer::Calendar.read_as("20261399")
  end

  test "each event in a calendar is a section of its own, so a passage never runs across two" do
    tenant = Tenant.create!(subdomain: "calendar-#{SecureRandom.hex(4)}", name: "Calendar")
    events = (1..12).map do |day|
      "BEGIN:VEVENT\r\nSUMMARY:Site visit #{day}\r\nDTSTART:202609#{format('%02d', day)}T090000\r\n" \
        "DESCRIPTION:#{'Bring the ladder and the moisture meter. ' * 4}\r\nEND:VEVENT\r\n"
    end
    body = "BEGIN:VCALENDAR\r\n#{events.join}END:VCALENDAR\r\n"

    Tenant.switch(tenant) do
      storage = Resource::Database.create!(key: "desk", name: "Desk")
      storage.upload("visits.ics", body)
      feed = Feed.create!(type: Feed::FILE, key: "visits.ics", title: "visits.ics")
      Reference.record!(feed: feed, resource: storage, locator_key: "visits.ics", mime: "text/calendar",
                        locator: { "key" => "visits.ics" })
      analysis = Analysis.open!(feed: feed, cause: "manual")

      Analyzer.for(feed.reload, analysis: analysis).analyze
      analysis.finished!
      feed.reload
      Passage.cut!(feed)

      outline = feed.outline
      text = feed.readable_text

      assert_equal 12, outline.size
      assert_equal "Site visit 3, Thursday, September 3, 2026, 09:00", outline[2]["name"]
      assert text[outline[2]["from"]..].start_with?("Site visit 3 ·")
      assert(feed.passages.all? { |passage| passage.text.scan("Site visit").size == 1 })
    end
  end
end
