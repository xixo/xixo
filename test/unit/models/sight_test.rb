require "test_helper"
require "vips"

class SightTest < ActiveSupport::TestCase
  test "an image is shrunk to fit the edge, keeps its shape, and loses its EXIF tags" do
    held = Vips::Image.new_from_buffer(Sight.prepared(tagged(2400, 1600)), "")

    assert_equal [ 1024, 683 ], [ held.width, held.height ]
    assert_not_includes held.get_fields, "exif-data"
    assert_empty held.get_fields.grep(/exif|SECRET/)
  end

  test "an image smaller than the edge keeps its size" do
    held = Vips::Image.new_from_buffer(Sight.prepared(tagged(640, 480)), "")

    assert_equal [ 640, 480 ], [ held.width, held.height ]
  end

  test "a transparent image is laid on white" do
    clear = Vips::Image.black(40, 40, bands: 4).pngsave_buffer
    held = Vips::Image.new_from_buffer(Sight.prepared(clear), "")

    assert_equal 3, held.bands
    assert_equal 255, held.avg.round
  end

  test "bytes that are not an image are refused" do
    assert_nil Sight.prepared("not an image")
    assert_nil Sight.prepared("")
  end

  private

    def tagged(width, height)
      plain = (Vips::Image.black(width, height, bands: 3) + 128).cast(:uchar).jpegsave_buffer
      tiff = "MM\x00\x2a\x00\x00\x00\x08".b + [ 1 ].pack("n") + [ 0x010e, 2, 7, 26 ].pack("nnNN") + [ 0 ].pack("N") + "SECRET\x00".b
      app1 = "Exif\x00\x00".b + tiff
      bytes = plain.b[0, 2] + "\xFF\xE1".b + [ app1.bytesize + 2 ].pack("n") + app1 + plain.b[2..]

      assert_includes Vips::Image.new_from_buffer(bytes, "").get_fields, "exif-data"
      bytes
    end
end
