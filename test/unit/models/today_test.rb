require "test_helper"

class TodayTest < ActiveSupport::TestCase
  test "the months, quarters, and years around today are spelled out" do
    said = Today.spans(Date.new(2026, 10, 4))

    assert_includes said, "This month is October 2026, and last month was September 2026."
    assert_includes said, "This quarter runs from October 1 to December 31, 2026, and last quarter ran from July 1 to September 30, 2026."
    assert_includes said, "This year is 2026, and last year was 2025."
  end

  test "last quarter in January is the end of last year" do
    assert_includes Today.spans(Date.new(2027, 1, 15)), "last quarter ran from October 1 to December 31, 2026"
  end
end
