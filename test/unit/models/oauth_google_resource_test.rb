require "test_helper"
require "masks/client/delegations/fake"

class OauthGoogleResourceTest < ActiveSupport::TestCase
  DRIVE = "https://www.googleapis.com/drive/v3".freeze

  setup do
    @masks = Delegations.fake = Masks::Client::Delegations::Fake.new
    @tenant = Tenant.create!(subdomain: "google-#{SecureRandom.hex(4)}", name: "Google")

    started = @masks.start(provider: "google")
    held = @masks.finish(params: @masks.approve(started, subject: "ada"), started: started)

    Tenant.switch(@tenant) do
      @resource = Resource::OauthGoogle.create!(key: "drive", name: "Drive",
                                                details: { "query" => "'shared' in parents or starred" })
      @resource.connect!(held, by: "ada")
    end

    @listed = []

    stub_request(:get, %r{\A#{DRIVE}/files\?}).to_return do |request|
      @asked = Rack::Utils.parse_query(URI(request.uri).query)["q"]
      json_response(files: @listed)
    end
  end

  teardown do
    Delegations.fake = nil
  end

  test "a search cannot close its quote and widen what the resource was limited to" do
    Tenant.switch(@tenant) { @resource.command_list(query: %q(x\' or name != ')) }

    assert_equal %q(trashed = false and name contains 'x\\\\\' or name != \'' and ('shared' in parents or starred)), @asked
  end

  test "the operator's own clause is grouped, so its or cannot outweigh the rest" do
    Tenant.switch(@tenant) { @resource.command_list(folder: "f'1") }

    assert_equal %q(trashed = false and 'f\'1' in parents and ('shared' in parents or starred)), @asked
  end

  test "get reads a file the resource's query reaches" do
    stub_file("1abc", "notes.txt")
    @listed = [ { "id" => "other" }, { "id" => "1abc" } ]

    found = Tenant.switch(@tenant) { @resource.command_get(id: "1abc") }

    assert_equal "remember the milk", found["text"]
    assert_equal %q(trashed = false and 'p1' in parents and ('shared' in parents or starred) and name = 'notes.txt'), @asked
  end

  test "get refuses a file the resource's query does not reach, before reading it" do
    stub_file("1abc", "notes.txt")
    @listed = [ { "id" => "other" } ]

    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command_get(id: "1abc") }
    end

    assert_not_requested :get, "#{DRIVE}/files/1abc", query: hash_including("alt" => "media")
  end

  test "a file is keyed on its id, since two files may share a name" do
    Tenant.switch(@tenant) do
      assert_equal "1abc", @resource.locator_key_for("id" => "1abc", "name" => "report.pdf")
    end
  end

  private

    def stub_file(id, name)
      stub_request(:get, "#{DRIVE}/files/#{id}").with(query: hash_including("fields" => Resource::OauthGoogle::FIELDS))
        .to_return(json_response(id: id, name: name, mimeType: "text/plain", parents: [ "p1" ]))
      stub_request(:get, "#{DRIVE}/files/#{id}").with(query: hash_including("alt" => "media"))
        .to_return(status: 200, body: "remember the milk")
    end
end
