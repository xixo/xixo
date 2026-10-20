require "test_helper"

class MimeFamilyTest < ActiveSupport::TestCase
  test "every content type belongs to one family, as the browser app groups rows" do
    assert_equal "pdf", MimeType.family("application/pdf")
    assert_equal "email", MimeType.family("message/rfc822")
    assert_equal "calendar", MimeType.family("text/calendar")
    assert_equal "contact", MimeType.family("text/vcard")
    assert_equal "data", MimeType.family("text/csv")
    assert_equal "text", MimeType.family("text/markdown")
    assert_equal "xlsx", MimeType.family("application/vnd.ms-excel")
    assert_equal "doc", MimeType.family("application/msword")
    assert_equal "image", MimeType.family("image/x-dcraw")
    assert_equal "video", MimeType.family("video/mp4")
    assert_equal "audio", MimeType.family("audio/mpeg")
    assert_equal "page", MimeType.family(MimeType::PAGE)
    assert_equal "pkpass", MimeType.family("application/vnd.apple.pkpass")
    assert_equal "file", MimeType.family("application/zip")
    assert_equal "file", MimeType.family(nil)
  end

  test "a reference is of the same kind in the database as its content type says in Ruby" do
    tenant = Tenant.create!(subdomain: "kinds-#{SecureRandom.hex(4)}", name: "Kinds")

    Tenant.switch(tenant) do
      mimes = %w[application/pdf text/csv text/markdown text/calendar image/png application/zip audio/ogg]
      feeds = mimes.index_with { |mime| create_feed(mime: mime, locator_key: "#{mime.tr('/', '-')}.bin") }
      feeds[nil] = create_feed(mime: nil, locator_key: "nameless")

      MimeType.families.each do |family|
        expected = feeds.select { |mime, _feed| MimeType.family(mime) == family }.values.map(&:id).sort

        assert_equal expected, Reference.originals.of_kind(family).pluck(:feed_id).sort, family
      end
    end
  end
end
