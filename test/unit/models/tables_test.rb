require "test_helper"

class TablesTest < ActiveSupport::TestCase
  LEDGER = [
    %w[Date Description Amount],
    [ "2026-08-02", "Fernwood Grocers", "-40.10" ],
    [ "2026-08-19", "Fernwood Grocers", "-1,060.25" ],
    [ "2026-09-01", "Fernwood Grocers", "-9.00" ],
    [ "2026-08-04", "Copperleaf Cafe", "-4.50" ]
  ].freeze

  test "a table an agent sent is kept only in the shape the server reads" do
    sound = Tables.sound("name" => "t", "columns" => [ "A", 2 ], "rows" => [ [ "x", { "nested" => 1 }, "extra" ], "not a row" ])

    assert_equal({ "name" => "t", "columns" => %w[A 2], "rows" => [ [ "x", '{"nested" => 1}' ] ] }, sound)
    assert_nil Tables.sound("name" => "t", "columns" => [], "rows" => [])
    assert_nil Tables.sound([ "not", "a", "table" ])
  end

  test "rows are narrowed by every test, and amounts with commas are numbers" do
    ledger = framed("ledger.csv", LEDGER)
    spec = { table: "ledger.csv", op: "sum", column: "Amount",
             where: [ [ "Description", "contains", "fernwood" ], [ "Date", "starts", "2026-08" ] ] }

    result = Tables.compute([ ledger ], spec)

    assert_equal(-1100.35, result["value"])
    assert_equal 2, result["rows"]
  end

  test "a count needs no column, and a comparison reads numbers" do
    mixed = framed("mixed.csv", [ %w[Payee Amount], [ "a", "40" ], [ "b", "-60" ], [ "c", "120" ] ])

    assert_equal 1, Tables.compute([ mixed ], { op: "count", where: [ [ "Amount", "<", "0" ] ] })["value"]
    assert_equal 2, Tables.compute([ mixed ], { op: "count", where: [ [ "Amount", ">", "-10" ] ] })["value"]
  end

  test "a result says what its rows hold, and what the whole table holds when nothing matched" do
    ledger = framed("ledger.csv", LEDGER)

    fernwood = Tables.compute([ ledger ], { op: "count", where: [ [ "Description", "contains", "fernwood" ] ] })
    assert_includes fernwood["spread"], "Description: Fernwood Grocers (3)"
    assert_includes fernwood["spread"], "Amount from -1060.25 to -9.0"

    nothing = Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", ">", "5000" ] ] })
    assert_equal 0, nothing["rows"]
    assert_includes nothing["spread"], "Amount from -1060.25 to -4.5"
  end

  test "a column that only ever goes out is compared by size, as a ledger means it" do
    ledger = framed("ledger.csv", LEDGER)

    assert_equal 2, Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", ">", "35" ] ] })["value"]
    assert_equal 2, Tables.compute([ ledger ], { op: "count", where: [ [ "Amount", "<", "-35" ] ] })["value"]
  end

  test "a negative bound on a column that only goes out means more spent than it, as the signs say" do
    ledger = framed("ledger.csv", LEDGER)

    over = Tables.compute([ ledger ], { op: "sum", column: "Amount", where: [ [ "Amount", "<", "-35" ] ] })["value"]
    under = Tables.compute([ ledger ], { op: "sum", column: "Amount", where: [ [ "Amount", ">=", "-35" ] ] })["value"]

    assert_in_delta(-1100.35, over)
    assert_in_delta(-13.5, under)
  end

  test "a date is compared as a date, so a quarter narrows a ledger" do
    ledger = framed("ledger.csv", LEDGER)

    august = Tables.compute([ ledger ], { op: "count", where: [ [ "Date", ">=", "2026-08-01" ], [ "Date", "<", "2026-09-01" ] ] })

    assert_equal 3, august["value"]
  end

  test "a table's shape is its columns, two rows, and what its columns hold, never every row" do
    shape = Tables.shape(framed("ledger.csv", LEDGER))

    assert_includes shape, "ledger.csv: Date, Description, Amount (4 rows)"
    assert_includes shape, "Description: Fernwood Grocers (3), Copperleaf Cafe (1)"
    assert_includes shape, "Amount from -1060.25 to -4.5"
    assert_includes shape, "Date from 2026-08-02 to 2026-09-01"
    assert_not_includes shape, "2026-08-04 (1)"
  end

  test "what cannot be worked out is refused with the reason" do
    ledger = framed("ledger.csv", LEDGER)

    assert_raises(Tables::Refused, match: /the columns are Date, Description, Amount/) do
      Tables.compute([ ledger ], { op: "sum", column: "Total" })
    end
    assert_raises(Tables::Refused, match: /op is one of/) { Tables.compute([ ledger ], { op: "median", column: "Amount" }) }
    assert_raises(Tables::Refused, match: /no table called/) { Tables.compute([ ledger, ledger ], { table: "x", op: "count" }) }
  end

  private

    def framed(name, rows)
      { "name" => name, "columns" => rows.first, "rows" => rows.drop(1) }
    end
end
