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

    stub_request(:get, %r{\A#{DRIVE}/files\?}).to_return do |request|
      @asked = Rack::Utils.parse_query(URI(request.uri).query)["q"]
      json_response(files: [])
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

  test "a file is keyed on its id, since two files may share a name" do
    Tenant.switch(@tenant) do
      assert_equal "1abc", @resource.locator_key_for("id" => "1abc", "name" => "report.pdf")
    end
  end
end
