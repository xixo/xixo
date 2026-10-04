require "test_helper"

class TablesTest < ActiveSupport::TestCase
  BUY_LIST = [
    [ "Elm Street Pantry: Buy List" ],
    [ "Quantities roll up from the Plan sheet." ],
    [ "Container", "Qty", "Unit price (CAD)", "Line total (CAD)" ],
    [ "Hartwell Square Jar 1L", 9, 8.25, 74.25 ],
    [ "Hartwell Square Jar 3L", 11, 17.75, 195.25 ],
    [ "TOTAL", 20, nil, 269.5 ],
    [],
    [ "A large order." ]
  ].freeze

  LEDGER = [
    %w[Date Description Amount],
    [ "2026-08-02", "Fernwood Grocers", "-40.10" ],
    [ "2026-08-19", "Fernwood Grocers", "-1,060.25" ],
    [ "2026-09-01", "Fernwood Grocers", "-9.00" ],
    [ "2026-08-04", "Copperleaf Cafe", "-4.50" ]
  ].freeze

  test "the header is the widest of the first rows, and the titles above it are dropped" do
    table = Tables.framed("Buy List", BUY_LIST)

    assert_equal [ "Container", "Qty", "Unit price (CAD)", "Line total (CAD)" ], table["columns"]
    assert_equal "Hartwell Square Jar 1L", table["rows"].first.first
    assert_equal 4, table["rows"].size, "blank rows go, and so does nothing else"
  end

  test "a sheet with no row of two cells is not a table" do
    assert_nil Tables.framed("Notes", [ [ "Just a line" ], [ "Another" ] ])
  end

  test "a sum leaves out the total row a sheet already has" do
    table = Tables.framed("Buy List", BUY_LIST)

    assert_equal 20.0, Tables.compute([ table ], { "table" => "buy list", "op" => "sum", "column" => "qty" })["value"]
  end

  test "rows are narrowed by every test, and amounts with commas are numbers" do
    ledger = Tables.framed("ledger.csv", LEDGER)
    spec = { table: "ledger.csv", op: "sum", column: "Amount",
             where: [ [ "Description", "contains", "fernwood" ], [ "Date", "starts", "2026-08" ] ] }

    result = Tables.compute([ ledger ], spec)

    assert_equal(-1100.35, result["value"])
    assert_equal 2, result["rows"]
  end

  test "a count needs no column, and a comparison reads numbers" do
    mixed = Tables.framed("mixed.csv", [ %w[Payee Amount], [ "a", "40" ], [ "b", "-60" ], [ "c", "120" ] ])

    assert_equal 1, Tables.compute([ mixed ], { op: "count", where: [ [ "Amount", "<", "0" ] ] })["value"]
    assert_equal 2, Tables.compute([ mixed ], { op: "count", where: [ [ "Amount", ">", "-10" ] ] })["value"]
  end

  test "a result says what its rows hold, and what the whole table holds when nothing matched" do
    ledger = Tables.framed("ledger.csv", LEDGER)

    fernwood = Tables.compute([ ledger ], { op: "count", where: [ [ "Description", "contains", "fernwood" ] ] })
    assert_includes fernwood["spread"], "Description: Fernwood Grocers (3)"
    assert_includes fernwood["spread"], "Amount from -1060.25 to -9.0"

    nothing = Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", ">", "5000" ] ] })
    assert_equal 0, nothing["rows"]
    assert_includes nothing["spread"], "Amount from -1060.25 to -4.5"
  end

  test "a column that only ever goes out is compared by size, as a ledger means it" do
    ledger = Tables.framed("ledger.csv", LEDGER)

    assert_equal 2, Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", ">", "35" ] ] })["value"]
    assert_equal 2, Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", "<", "-35" ] ] })["value"]
  end

  test "what cannot be worked out is refused with the reason" do
    ledger = Tables.framed("ledger.csv", LEDGER)

    assert_raises(Tables::Refused, match: /the columns are Date, Description, Amount/) do
      Tables.compute([ ledger ], { op: "sum", column: "Total" })
    end
    assert_raises(Tables::Refused, match: /op is one of/) { Tables.compute([ ledger ], { op: "median", column: "Amount" }) }
    assert_raises(Tables::Refused, match: /no table called/) { Tables.compute([ ledger, ledger ], { table: "x", op: "count" }) }
  end
end
