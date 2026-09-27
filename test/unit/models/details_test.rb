require "test_helper"

class DetailsTest < ActiveSupport::TestCase
  def held(result, at = "2026-09-27T10:00:00.000Z")
    { "started_at" => at, "result" => result }
  end

  def rows(steps)
    Details.new(steps).rows.map { |row| [ row.group, row.item, row.label, row.value ] }
  end

  test "a flat step becomes one group of labelled rows" do
    assert_equal [
      [ "Dimensions", nil, "Width", "6016" ],
      [ "Dimensions", nil, "Height", "4016" ]
    ], rows("dimensions" => held({ "width" => 6016, "height" => 4016 }))
  end

  test "steps that are text, verdicts, or bookkeeping are left out" do
    steps = {
      "text" => held("the whole body"),
      "ocr" => held("7 7"),
      "summary" => held({ "summary" => "A family on a lake." }),
      "deviation" => held(36.1),
      "placement" => held({ "path" => "a.jpg" }),
      "verified" => held({ "score" => 0.9 })
    }

    assert_empty rows(steps)
  end

  test "embedded metadata comes last, and the names that matter most come first" do
    steps = {
      "metadata" => held({ "WhiteBalance" => "Auto", "Model" => "NIKON D750", "Make" => "NIKON" }, "2026-09-27T09:00:00.000Z"),
      "dimensions" => held({ "width" => 10 }, "2026-09-27T10:00:00.000Z")
    }

    assert_equal [
      [ "Dimensions", nil, "Width", "10" ],
      [ "Embedded in the file", nil, "Make", "NIKON" ],
      [ "Embedded in the file", nil, "Model", "NIKON D750" ],
      [ "Embedded in the file", nil, "White balance", "Auto" ]
    ], rows(steps)
  end

  test "a list of records numbers each record, and a list of names reads as one row" do
    steps = {
      "attachments" => held([ { "filename" => "a.png", "size" => 48_085 }, { "filename" => "b.pdf" } ]),
      "listing" => held(%w[notes.txt rows.csv])
    }

    assert_includes rows(steps), [ "Attachments", 1, "Size", "47 KB" ]
    assert_includes rows(steps), [ "Attachments", 2, "Filename", "b.pdf" ]
    assert_includes rows(steps), [ "Contents", nil, "Contents", "notes.txt, rows.csv" ]
  end

  test "a label and value pair reads as its own row" do
    steps = { "pass" => held({ "fields" => [ { "label" => "CREDIT", "value" => "250.0" } ] }) }

    assert_equal [ [ "Pass", nil, "CREDIT", "250.0" ] ], rows(steps)
  end

  test "what an earlier step already said is not said again" do
    steps = {
      "info" => held({ "title" => "Invoice" }, "2026-09-27T09:00:00.000Z"),
      "metadata" => held({ "Title" => "Invoice", "Producer" => "pdfTeX" }, "2026-09-27T10:00:00.000Z")
    }

    assert_equal [
      [ "Document", nil, "Title", "Invoice" ],
      [ "Embedded in the file", nil, "Producer", "pdfTeX" ]
    ], rows(steps)
  end

  test "long values are cut and a list of lists is skipped" do
    steps = { "sheets" => held([ { "name" => "Ledger", "sample" => [ [ "a", 1 ] ], "memo" => "x" * 1000 } ]) }
    found = rows(steps)

    assert_equal [ "Name", "Memo" ], found.map { |row| row[2] }
    assert_equal Details::VALUE, found.last[3].length
  end

  test "labels read as words" do
    assert_equal "Lens ID", Details.label("LensID")
    assert_equal "GPS latitude", Details.label("GPSLatitude")
    assert_equal "Focal length in 35mm format", Details.label("FocalLengthIn35mmFormat")
    assert_equal "Page size", Details.label("page_size")
  end
end
