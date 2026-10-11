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

  test "a sync catalogues files and Google's own documents as files the analyzers read, leaving out folders and forms" do
    @listed = [
      { id: "f1", name: "lease.pdf", mimeType: "application/pdf", md5Checksum: "aa", modifiedTime: "2026-10-01T00:00:00Z" },
      { id: "d1", name: "Roof plan", mimeType: "application/vnd.google-apps.document", modifiedTime: "2026-10-02T00:00:00Z" },
      { id: "x1", name: "Signup", mimeType: "application/vnd.google-apps.form", modifiedTime: "2026-10-02T00:00:00Z" },
      { id: "p1", name: "Shed", mimeType: Resource::OauthGoogle::FOLDER, modifiedTime: "2026-10-02T00:00:00Z" }
    ]
    stub_request(:get, "#{DRIVE}/changes/startPageToken").with(query: hash_including({}))
      .to_return(json_response(startPageToken: "t100"))

    Tenant.switch(@tenant) do
      @resource.update_columns(details: {})
      SyncResourceJob.perform_now(@tenant.id, @resource.id)

      plan = Reference.find_by!(resource: @resource, locator_key: "d1")

      assert_equal %w[d1 f1], Reference.where(resource: @resource).order(:locator_key).pluck(:locator_key)
      assert_equal "Roof plan.docx", plan.feed.title
      assert_equal Resource::OauthGoogle::EXPORTS.dig("application/vnd.google-apps.document", 0), plan.mime
      assert_equal({ "page_token" => "t100" }, @resource.reload.sync_state["checkpoint"])
    end
    assert_includes @asked, "mimeType != '#{Resource::OauthGoogle::FOLDER}'"
  end

  test "a sync after a full walk reads only Drive's changes, and a removed file is gone" do
    stub_request(:get, "#{DRIVE}/changes").with(query: hash_including("pageToken" => "t100"))
      .to_return(json_response(newStartPageToken: "t101", changes: [
        { fileId: "f1", removed: true },
        { fileId: "f2", file: { id: "f2", name: "new.txt", mimeType: "text/plain", md5Checksum: "bb" } }
      ]))

    Tenant.switch(@tenant) do
      @resource.update_columns(details: {}, sync_state: { "checkpoint" => { "page_token" => "t100" } }, walked_at: 1.hour.ago)
      @resource.keep!({ "id" => "f1", "name" => "old.txt", "mimeType" => "text/plain", "md5Checksum" => "aa" }, cause: "keep")

      SyncResourceJob.perform_now(@tenant.id, @resource.id)

      assert Reference.find_by!(resource: @resource, locator_key: "f1").gone_at.present?
      assert Reference.exists?(resource: @resource, locator_key: "f2")
      assert_equal({ "page_token" => "t101" }, @resource.reload.sync_state["checkpoint"])
    end
    assert_not_requested :get, %r{\A#{DRIVE}/files\?}
  end

  test "a changed file that has left the resource's query is gone, and a lookup Drive refuses does not stop the walk" do
    stub_request(:get, "#{DRIVE}/changes").with(query: hash_including("pageToken" => "t100"))
      .to_return(json_response(newStartPageToken: "t101", changes: [
        { fileId: "f1", file: { id: "f1", name: "moved.txt", mimeType: "text/plain", parents: [ "elsewhere" ] } },
        { fileId: "f2", file: { id: "f2", name: "unshared.txt", mimeType: "text/plain", parents: [ "p9" ] } }
      ]))
    stub_request(:get, %r{\A#{DRIVE}/files\?}).with(query: hash_including("q" => /'p9' in parents/))
      .to_return(status: 403, body: "{}")

    Tenant.switch(@tenant) do
      @resource.update_columns(sync_state: { "checkpoint" => { "page_token" => "t100" } }, walked_at: 1.hour.ago)
      @resource.keep!({ "id" => "f1", "name" => "moved.txt", "mimeType" => "text/plain", "md5Checksum" => "aa" }, cause: "keep")

      SyncResourceJob.perform_now(@tenant.id, @resource.id)

      assert Reference.find_by!(resource: @resource, locator_key: "f1").gone_at.present?
      assert_not Reference.exists?(resource: @resource, locator_key: "f2")
      assert_equal({ "page_token" => "t101" }, @resource.reload.sync_state["checkpoint"])
    end
  end

  test "a Google document is downloaded as the file it exports to" do
    stub_request(:get, "#{DRIVE}/files/d1/export")
      .with(query: hash_including("mimeType" => Resource::OauthGoogle::EXPORTS.dig("application/vnd.google-apps.document", 0)))
      .to_return(status: 200, body: "docx bytes")

    Tenant.switch(@tenant) do
      locator = @resource.locator_for({ "id" => "d1", "name" => "Roof plan", "mimeType" => "application/vnd.google-apps.document" })

      assert_equal "docx bytes", @resource.download(locator).read
    end
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
