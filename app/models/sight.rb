class Sight
  EDGE = 1024
  QUALITY = 85
  WHITE = [ 255, 255, 255 ].freeze

  def self.prepared(bytes, edge: EDGE)
    return nil if bytes.blank?

    require "vips"

    image = Vips::Image.thumbnail_buffer(bytes, edge, height: edge, size: :down, export_profile: "srgb")
    image = image.flatten(background: WHITE) if image.has_alpha?
    image.jpegsave_buffer(Q: QUALITY, **stripped)
  rescue Vips::Error => e
    Rails.logger.warn "an image could not be prepared for the vision model: #{e.message.squish.truncate(200)}"
    nil
  end

  def self.stripped
    Vips.at_least_libvips?(8, 15) ? { keep: :none } : { strip: true }
  end
end
