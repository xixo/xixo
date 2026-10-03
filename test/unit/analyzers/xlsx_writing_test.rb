require "test_helper"

class XlsxWritingTest < ActiveSupport::TestCase
  Sheet = Struct.new(:rows) do
    def first_row = rows.empty? ? nil : 1
    def last_row = rows.empty? ? nil : rows.size
    def last_column = rows.map(&:size).max
    def cell(row, column) = rows.dig(row - 1, column - 1)
  end

  Workbook = Struct.new(:held) do
    def sheets = held.keys
    def sheet(name) = held.fetch(name)
  end

  PANTRY = [ [ "Item", "Container", "Qty" ] ] + (1..56).map { |at| [ "Item #{at}", "Kilner 1L", 1 ] }
  BUY = [ [ "Container", "Qty" ], [ "Kilner Square Clip Top 1L", 11 ], [ "Kilner Square Clip Top 3L", 13 ] ]

  def written(sheets) = Analyzer::Xlsx.written_out(Workbook.new(sheets))

  test "every row of every sheet is in the text, not a sample of each" do
    text, = written("Pantry Plan" => Sheet.new(PANTRY), "Buy List" => Sheet.new(BUY))

    assert_includes text, "Item 56 | Kilner 1L | 1"
    assert_includes text, "Kilner Square Clip Top 3L | 13"
  end

  test "the outline says where each sheet starts in the text" do
    text, outline = written("Pantry Plan" => Sheet.new(PANTRY), "Empty" => Sheet.new([]), "Buy List" => Sheet.new(BUY))

    assert_equal [ "Pantry Plan", "Empty", "Buy List" ], outline.map { |part| part["name"] }
    assert_equal [ 57, 0, 3 ], outline.map { |part| part["rows"] }

    bought = outline.last

    assert text[bought["from"]..].start_with?("Buy List\nContainer | Qty\nKilner Square Clip Top 1L | 11")
  end

  test "a workbook past the text limit stops at it, and the outline names only what made it in" do
    huge = [ [ "x" * 150 ] ] * 2_000
    text, outline = written("One" => Sheet.new(huge), "Two" => Sheet.new(huge))

    assert_operator text.length, :<=, Analyzer::Base::MAX_TEXT
    assert_equal [ "One" ], outline.map { |part| part["name"] }
  end
end
