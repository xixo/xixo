require "test_helper"
require "masks/client/delegations/fake"

class MicrosoftGraphResourceTest < ActiveSupport::TestCase
  API = "https://graph.microsoft.com/v1.0".freeze

  setup do
    SearchIndex.reset!

    @masks = Delegations.fake = Masks::Client::Delegations::Fake.new

    @tenant = Tenant.create!(subdomain: "ms-#{SecureRandom.hex(4)}", name: "Microsoft")

    started = @masks.start(provider: "microsoft")
    held = @masks.finish(params: @masks.approve(started, subject: "ash"), started: started)

    Tenant.switch(@tenant) do
      @resource = Resource::MicrosoftGraph.create!(key: "onedrive", name: "OneDrive")
      @resource.connect!(held, by: "ash")
    end
  end

  teardown do
    Delegations.fake = nil
  end

  test "the stored type is microsoft-graph, it connects through masks, and it syncs" do
    assert_equal "microsoft-graph", @resource.type
    assert @resource.delegated?
    assert_equal "microsoft", @resource.provider_key
    assert @resource.syncable?
  end

  test "no credential is ever typed in — the form asks for a folder and nothing else" do
    assert_equal [ "folder" ], Resource::MicrosoftGraph.attaching[:fields].map { |field| field[:name] }
    assert_empty Resource::MicrosoftGraph.attaching[:fields].select { |field| field[:secret] }
  end

  test "the token masks releases is what reaches Microsoft" do
    stub_request(:get, "#{API}/me").to_return(json_response(id: "u1", userPrincipalName: "ash@acme.test"))
    stub_request(:get, "#{API}/me/drive").to_return(json_response(id: "d1"))

    Tenant.switch(@tenant) { assert @resource.check! }

    assert_requested :get, "#{API}/me", headers: { "Authorization" => "Bearer microsoft-access-1" }
  end

  test "an account with no drive is unusable, and says which account" do
    stub_request(:get, "#{API}/me").to_return(json_response(id: "u1", userPrincipalName: "ash@acme.test"))
    stub_request(:get, "#{API}/me/drive").to_return(json_response({}))

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { @resource.check! } }

    assert_match(/ash@acme\.test/, error.message)
  end

  test "a delta page hands back its own next link as the cursor" do
    stub_request(:get, "#{API}/me/drive/root/delta")
      .to_return(json_response(value: [ file("report.pdf") ],
                      "@odata.nextLink": "#{API}/me/drive/root/delta?token=abc"))

    stub_request(:get, "#{API}/me/drive/root/delta?token=abc")
      .to_return(json_response(value: [ file("notes.txt") ], "@odata.deltaLink": "#{API}/delta?token=done"))

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, cursor| seen << [ batch.length, cursor ] } }

    assert_equal [ [ 1, "#{API}/me/drive/root/delta?token=abc" ], [ 1, nil ] ], seen
  end

  test "a resumed sync asks for the page it had not reached, not the first one" do
    stub_request(:get, "#{API}/me/drive/root/delta?token=abc")
      .to_return(json_response(value: [ file("notes.txt") ]))

    Tenant.switch(@tenant) do
      @resource.each_page(cursor: "#{API}/me/drive/root/delta?token=abc") { |_batch, _cursor| nil }
    end

    assert_not_requested :get, "#{API}/me/drive/root/delta"
  end

  test "folders and deletions are not items, and a file is keyed on its id" do
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(value: [
      file("report.pdf", path: "/drive/root:/Invoices"),
      { "id" => "f1", "name" => "Invoices", "folder" => { "childCount" => 2 } },
      { "id" => "g1", "name" => "gone.txt", "deleted" => { "state" => "deleted" } }
    ]))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal "i-report-pdf", Feed.last.locator_key
      assert_equal "Invoices/report.pdf", Reference.last.locator["path"]
      assert_equal "report.pdf", Feed.last.title
      assert_equal "application/pdf", Feed.last.mime, "the mime still comes from the name"
    end
  end

  test "a delta that omits paths takes them from the folders it has already listed" do
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(value: [
      { "id" => "r", "name" => "root", "root" => {}, "folder" => {} },
      folder("f-a", "2025", parent: "r"),
      folder("f-b", "2026", parent: "r"),
      pathless("report.pdf", id: "one", parent: "f-a"),
      pathless("report.pdf", id: "two", parent: "f-b")
    ]))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 2, Feed.files.count, "two files of one name in two folders are two items"
      assert_equal [ "2025/report.pdf", "2026/report.pdf" ], Reference.all.map { |held| held.locator["path"] }.sort
    end

    assert_not_requested :get, %r{#{API}/me/drive/items/}
  end

  test "a parent the delta has not listed is looked up once" do
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(value: [
      pathless("a.txt", id: "a", parent: "f1"),
      pathless("b.txt", id: "b", parent: "f1")
    ]))
    stub_request(:get, "#{API}/me/drive/items/f1").with(query: hash_including({}))
      .to_return(json_response(id: "f1", name: "Invoices", parentReference: { path: "/drive/root:/Work" }))

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, _| seen += batch } }

    paths = Tenant.switch(@tenant) { seen.map { |entry| @resource.locator_for(entry)["path"] } }

    assert_equal [ "Work/Invoices/a.txt", "Work/Invoices/b.txt" ], paths
    assert_requested :get, %r{#{API}/me/drive/items/f1}, times: 1
  end

  test "the next sync starts from the delta link, and a deletion it reports is gone" do
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(
      value: [ file("keep.txt"), file("drop.txt") ], "@odata.deltaLink": "#{API}/me/drive/root/delta?token=one"
    ))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    stub_request(:get, "#{API}/me/drive/root/delta?token=one").to_return(json_response(
      value: [ { "id" => "i-drop-txt", "deleted" => { "state" => "deleted" } } ],
      "@odata.deltaLink": "#{API}/me/drive/root/delta?token=two"
    ))

    Tenant.switch(@tenant) do
      @resource.reload
      SyncResourceJob.perform_now(@tenant.id, @resource.id)

      assert_nil Reference.find_by(locator_key: "i-keep-txt").gone_at, "a walk of changes marks nothing it did not visit"
      assert_not_nil Reference.find_by(locator_key: "i-drop-txt").gone_at
      assert_equal "#{API}/me/drive/root/delta?token=two", @resource.reload.sync_state["checkpoint"]["delta"]
    end

    assert_requested :get, "#{API}/me/drive/root/delta", times: 1
  end

  test "a file moved out of the folder is gone" do
    Tenant.switch(@tenant) { @resource.update!(details: { "folder" => "Invoices" }) }

    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(
      value: [ file("report.pdf", path: "/drive/root:/Invoices") ],
      "@odata.deltaLink": "#{API}/me/drive/root/delta?token=one"
    ))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    stub_request(:get, "#{API}/me/drive/root/delta?token=one").to_return(json_response(
      value: [ file("report.pdf", path: "/drive/root:/Archive") ]
    ))

    Tenant.switch(@tenant) do
      SyncResourceJob.perform_now(@tenant.id, @resource.reload.id)

      assert_not_nil Reference.find_by(locator_key: "i-report-pdf").gone_at
    end
  end

  test "a full walk marks what it no longer finds as gone" do
    stub_request(:get, "#{API}/me/drive/root/delta")
      .to_return(json_response(value: [ file("a.txt"), file("b.txt") ]))
      .then.to_return(json_response(value: [ file("a.txt") ]))

    Tenant.switch(@tenant) do
      sync
      travel 1.minute
      sync

      assert_nil Reference.find_by(locator_key: "i-a-txt").gone_at
      assert_not_nil Reference.find_by(locator_key: "i-b-txt").gone_at
    end
  end

  test "an expired delta link starts the walk over from the top" do
    Tenant.switch(@tenant) do
      @resource.update_columns(sync_state: { "checkpoint" => { "delta" => "#{API}/me/drive/root/delta?token=old" } },
                               walked_at: 1.hour.ago)
    end

    stub_request(:get, "#{API}/me/drive/root/delta?token=old")
      .to_return(status: 410, body: { error: { code: "resyncRequired", message: "resync" } }.to_json)
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(
      value: [ file("a.txt") ], "@odata.deltaLink": "#{API}/me/drive/root/delta?token=new"
    ))

    Tenant.switch(@tenant) do
      SyncResourceJob.perform_now(@tenant.id, @resource.id)

      assert_equal 1, Feed.files.count
      assert_equal "#{API}/me/drive/root/delta?token=new", @resource.reload.sync_state["checkpoint"]["delta"]
      assert_operator @resource.walked_at, :>, 1.minute.ago, "the walk that started over was a full one"
    end
  end

  test "keep catalogues one file by its id" do
    stub_request(:get, "#{API}/me/drive/items/i-report-pdf").to_return(json_response(file("report.pdf")))

    kept = Tenant.switch(@tenant) { @resource.command_keep(id: "i-report-pdf") }

    assert_equal "i-report-pdf", kept["key"]
    assert_equal "report.pdf", kept["title"]
  end

  test "an id that would climb out of the items path is refused before it is sent" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command_keep(id: "../../users/someone") }
      assert_raises(ArgumentError) { @resource.command_get(id: "..") }
      assert_raises(ArgumentError) { @resource.command_get(id: "i1?$expand=children") }
    end

    assert_not_requested :any, /graph\.microsoft\.com/
  end

  test "keep refuses a folder" do
    stub_request(:get, "#{API}/me/drive/items/f1").to_return(json_response(folder("f1", "Invoices", parent: "r")))

    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command_keep(id: "f1") }
    end
  end

  test "a folder in the details narrows what is catalogued" do
    Tenant.switch(@tenant) { @resource.update!(details: { "folder" => "Invoices" }) }

    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(value: [
      file("report.pdf", path: "/drive/root:/Invoices"),
      file("holiday.jpg", path: "/drive/root:/Photos")
    ]))

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, _| seen += batch } }

    assert_equal [ "report.pdf" ], seen.map { |entry| entry["name"] }
  end

  test "a changed file is a new version" do
    Tenant.switch(@tenant) do
      assert_equal "ctag-1", @resource.version_for(@resource.locator_for(file("a.pdf", ctag: "ctag-1")))
      assert_equal "ctag-2", @resource.version_for(@resource.locator_for(file("a.pdf", ctag: "ctag-2")))
    end
  end

  test "content follows the redirect Microsoft answers with, unauthenticated" do
    stub_request(:get, "#{API}/me/drive/items/i1/content")
      .to_return(status: 302, headers: { "Location" => "https://acme.sharepoint.test/download/i1" })

    stub_request(:get, "https://acme.sharepoint.test/download/i1")
      .to_return(status: 200, body: "the bytes")

    bytes = Tenant.switch(@tenant) { @resource.download("id" => "i1").read }

    assert_equal "the bytes", bytes
    assert_requested :get, "https://acme.sharepoint.test/download/i1" do |request|
      request.headers["Authorization"].nil?
    end
  end

  test "a redirect pointing back inside the network is refused rather than followed" do
    stub_request(:get, "#{API}/me/drive/items/i1/content")
      .to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/meta-data/" })

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Unusable) { @resource.download("id" => "i1") }

      assert_match(/169\.254\.169\.254|reserved|private/i, error.message)
    end
  end

  test "a token masks released but Microsoft refuses is released once more, then given up on" do
    stub_request(:get, "#{API}/me").to_return(status: 401, body: "{}")

    Tenant.switch(@tenant) do
      assert_raises(Resource::Unusable) { @resource.check! }
    end

    assert_equal 2, @masks.releases, "an expired token is worth one more release"
    assert_requested :get, "#{API}/me", times: 2
  end

  test "OneDrive syncs on its schedule with nobody signed in" do
    stub_request(:get, "#{API}/me/drive/root/delta").to_return(json_response(value: [ file("report.pdf") ]))

    Current.reset
    Tenant.switch(@tenant) do
      @resource.update!(sync_interval: 1.hour.to_i)
      SyncResourceJob.perform_now(@tenant.id, @resource.id)
    end

    assert_nil Current.grant
    assert_equal 1, Tenant.switch(@tenant) { Feed.files.count }
    assert_requested :get, "#{API}/me/drive/root/delta", headers: { "Authorization" => "Bearer microsoft-access-1" }
  end

  private

    def sync
      @resource.reload.claim_sync!
      SyncResourceJob.perform_now(@tenant.id, @resource.id)
    end

    def folder(id, name, parent:)
      { "id" => id, "name" => name, "folder" => { "childCount" => 1 }, "parentReference" => { "id" => parent } }
    end

    def pathless(name, id:, parent:)
      file(name).merge("id" => id, "parentReference" => { "id" => parent })
    end

    def file(name, path: "/drive/root:", ctag: "ctag-1")
      {
        "id" => "i-#{name.tr(".", "-")}", "name" => name, "size" => 120,
        "file" => { "mimeType" => "application/octet-stream" },
        "cTag" => ctag, "lastModifiedDateTime" => "2026-09-01T10:00:00Z",
        "parentReference" => { "path" => path }
      }
    end
end
