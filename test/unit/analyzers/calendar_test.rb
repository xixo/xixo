require "test_helper"

class CalendarTest < ActiveSupport::TestCase
  test "a calendar's dates are written the way a person reads them" do
    assert_equal "Tuesday, November 3, 2026, 14:15", Analyzer::Calendar.read_as("20261103T141500")
    assert_equal "Sunday, August 30, 2026, 08:00 UTC", Analyzer::Calendar.read_as("20260830T080000Z")
    assert_equal "Tuesday, September 1, 2026", Analyzer::Calendar.read_as("20260901")
    assert_equal "soon", Analyzer::Calendar.read_as("soon")
    assert_equal "20261399", Analyzer::Calendar.read_as("20261399")
  end
end
