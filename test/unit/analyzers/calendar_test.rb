require "test_helper"

class CalendarTest < ActiveSupport::TestCase
  test "a calendar's dates are written the way a person reads them" do
    assert_equal "Tuesday, November 3, 2026, 14:15", Analyzer::Calendar.read_as("20261103T141500")
    assert_equal "Sunday, August 30, 2026, 08:00 UTC", Analyzer::Calendar.read_as("20260830T080000Z")
    assert_equal "Tuesday, September 1, 2026", Analyzer::Calendar.read_as("20260901")
    assert_equal "soon", Analyzer::Calendar.read_as("soon")
    assert_equal "20261399", Analyzer::Calendar.read_as("20261399")
  end

  test "each event xixo link marks as a section stays its own, so a passage never runs across two" do
    tenant = Tenant.create!(subdomain: "calendar-#{SecureRandom.hex(4)}", name: "Calendar")
    lines = (1..12).map do |day|
      "Site visit #{day} · #{Analyzer::Calendar.read_as("202609#{format('%02d', day)}T090000")} · " \
        "#{'Bring the ladder and the moisture meter. ' * 4}".strip
    end
    from = 0
    outline = lines.each_with_index.map do |line, index|
      part = { "name" => "Site visit #{index + 1}", "from" => from }
      from += line.length + 1
      part
    end
    FakeLink.script = ->(*) { FakeLink.extracted({ "text" => lines.join("\n"), "outline" => outline }, extractor: "calendar") }

    Tenant.switch(tenant) do
      storage = Resource::Database.create!(key: "desk", name: "Desk")
      storage.upload("visits.ics", "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
      feed = Feed.create!(type: Feed::FILE, key: "visits.ics", title: "visits.ics")
      Reference.record!(feed: feed, resource: storage, locator_key: "visits.ics", mime: "text/calendar",
                        locator: { "key" => "visits.ics" })
      analysis = Analysis.open!(feed: feed, cause: "manual")

      Analyzer.for(feed.reload, analysis: analysis).extract!
      analysis.finished!
      feed.reload
      Passage.cut!(feed)

      held = feed.outline
      text = feed.readable_text

      assert_equal 12, held.size
      assert text[held[2]["from"]..].start_with?("Site visit 3 ·")
      assert(feed.passages.all? { |passage| passage.text.scan("Site visit").size == 1 })
    end
  end
end
