require "test_helper"
require_relative "../../support/fake_dav_server"

class CarddavResourceTest < ActiveSupport::TestCase
  CARD = <<~'VCF'.gsub("\n", "\r\n").freeze
    BEGIN:VCARD
    VERSION:3.0
    FN:Jane Pelican
    N:Pelican;Jane;;;
    ORG:Estuary Birds Ltd.
    TITLE:Chief Wader
    item1.EMAIL;TYPE=INTERNET;TYPE=WORK:jane@estuary.example
    TEL;TYPE=CELL:+44 7700 900000
    ADR;TYPE=WORK:;;Pelican House\, Unit 3\; rear;Poole;Dorset;BH15;England
    NOTE:Prefers to be contacted about anything at all to do with the tide
      tables\, especially in winter.
    END:VCARD
  VCF

  setup do
    SearchIndex.reset!

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeDavServer.current
    @server.reset!
    @server.put "contacts/jane.vcf", CARD, type: "text/vcard; charset=utf-8"
    @server.put "contacts/readme.txt", "not a contact"

    @tenant = Tenant.create!(subdomain: "card-#{SecureRandom.hex(4)}", name: "Contacts")

    Tenant.switch(@tenant) do
      @resource = Resource::Carddav.create!(
        key: "card-#{SecureRandom.hex(4)}",
        name: "Contacts",
        details: { "url" => @server.url },
        credentials: { "username" => "someone", "password" => "irrelevant" }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "only vcards are catalogued, and they are contacts" do
    sync

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal "text/vcard", Feed.first.mime
      assert_equal "contacts/jane.vcf", Reference.first.locator_key
    end
  end

  test "a legacy content type and a bare .vcf are both claimed" do
    @server.put "contacts/old.vcf", CARD, type: "text/x-vcard"
    @server.put "contacts/untyped.vcf", CARD, type: "application/octet-stream"

    sync

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
  end

  test "a .vcf arriving from anywhere else is a contact too" do
    assert_equal "text/vcard", MimeType.for_filename("exported/addresses.vcf")
  end

  test "contacts are read-only and cannot be an export destination" do
    assert_not @resource.storage?
    assert_raises(ArgumentError) { @resource.storage! }
    assert_not @resource.class.command_schema.key?(:put)
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end
end
