module Geotag
  module_function

  def jpeg(bytes, latitude:, longitude:)
    raise ArgumentError, "not a jpeg" unless bytes.b.start_with?("\xFF\xD8".b)

    exif = "Exif\0\0".b + tiff(latitude, longitude)
    "\xFF\xD8".b + [ 0xFFE1, exif.bytesize + 2 ].pack("nn") + exif + bytes.b.byteslice(2..)
  end

  def tiff(latitude, longitude)
    gps_at = 26
    data_at = gps_at + 2 + (4 * 12) + 4

    head = "MM".b + [ 42, 8 ].pack("nN")
    ifd0 = [ 1, 0x8825, 4, 1, gps_at, 0 ].pack("nnnNNN")
    gps = [ 4 ].pack("n") +
          entry(1, 2, 2, (latitude.negative? ? "S" : "N").b + "\0\0\0".b) +
          [ 2, 5, 3, data_at ].pack("nnNN") +
          entry(3, 2, 2, (longitude.negative? ? "W" : "E").b + "\0\0\0".b) +
          [ 4, 5, 3, data_at + 24 ].pack("nnNN") +
          [ 0 ].pack("N")

    head + ifd0 + gps + rationals(latitude.abs) + rationals(longitude.abs)
  end

  def entry(tag, type, count, value)
    [ tag, type, count ].pack("nnN") + value.byteslice(0, 4)
  end

  def rationals(degrees)
    whole = degrees.floor
    minutes = ((degrees - whole) * 60).floor
    seconds = ((((degrees - whole) * 60) - minutes) * 60 * 100).round

    [ whole, 1, minutes, 1, seconds, 100 ].pack("N6")
  end
end
