require "test_helper"

class OutlineTest < ActiveSupport::TestCase
  test "a stored outline is the outline" do
    stored = [ { "name" => "Buy List", "from" => 7254 } ]

    assert_equal stored, Outline.of("anything", stored: stored)
  end

  test "markdown headings are sections, starting where the heading does" do
    text = "# Lease\n\nIntro.\n\n## 17. Ending the tenancy\n\nSixty days."
    outline = Outline.of(text)

    assert_equal [ "Lease", "17. Ending the tenancy" ], outline.map { |part| part["name"] }
    assert_equal "## 17.", text[outline.last["from"], 6]
  end

  test "form feeds between pdf pages make pages" do
    outline = Outline.of("one\fthree\f")

    assert_equal [ [ "Page 1", 0 ], [ "Page 2", 4 ] ], outline.map { |part| [ part["name"], part["from"] ] }
  end

  test "a plain text has no outline" do
    assert_empty Outline.of("Just a note about the shed.")
  end

  test "the section at an offset is the last one started before it" do
    outline = [ { "name" => "Plan", "from" => 987 }, { "name" => "Buy List", "from" => 7254 } ]

    assert_nil Outline.at(outline, 10)
    assert_equal "Plan", Outline.at(outline, 7253)
    assert_equal "Buy List", Outline.at(outline, 7254)
  end
end
