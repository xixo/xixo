require "test_helper"

class NotionResourceTest < ActiveSupport::TestCase
  API = "https://api.notion.com/v1".freeze
  PAGE_ID = "1f0e2a3b-4c5d-6e7f-8091-a2b3c4d5e6f7".freeze

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "no-#{SecureRandom.hex(4)}", name: "Notion")

    Tenant.switch(@tenant) do
      @resource = Resource::Notion.create!(
        key: "notion", name: "Workspace",
        details: {}, credentials: { "token" => "ntn_secret" }
      )
    end
  end

  test "the stored type is notion, it syncs, and it holds no bytes of its own" do
    assert_equal "notion", @resource.type
    assert @resource.syncable?
    assert_not @resource.storage?
  end

  test "check passes when the secret names an integration" do
    stub_request(:get, "#{API}/users/me").to_return(json_response(id: "bot-1", name: "xixo"))

    Tenant.switch(@tenant) { assert @resource.check! }
  end

  test "a secret Notion refuses is unusable rather than a failure to retry" do
    stub_request(:get, "#{API}/users/me")
      .to_return(status: 401, body: { message: "API token is invalid." }.to_json)

    Tenant.switch(@tenant) do
      assert_match(/refused the token/, assert_raises(Resource::Unusable) { @resource.check! }.message)
    end
  end

  test "the version header travels on every call" do
    stub_request(:get, "#{API}/users/me").to_return(json_response(id: "bot-1"))

    Tenant.switch(@tenant) { @resource.check! }

    assert_requested :get, "#{API}/users/me", headers: { "Notion-Version" => "2022-06-28" }
  end

  test "a sync walks the cursor Notion hands back and stops when it says so" do
    stub_request(:post, "#{API}/search")
      .with(body: hash_excluding("start_cursor"))
      .to_return(json_response(results: [ page("a"), database("d") ], has_more: true, next_cursor: "c1"))

    stub_request(:post, "#{API}/search")
      .with(body: hash_including("start_cursor" => "c1"))
      .to_return(json_response(results: [ page("b") ], has_more: false, next_cursor: nil))

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, cursor| seen << [ batch.length, cursor ] } }

    assert_equal [ [ 1, "c1" ], [ 1, nil ] ], seen,
                 "a database is not a page, and must not become an item"
  end

  test "a page lands keyed on its id, titled from its title property" do
    stub_request(:post, "#{API}/search")
      .to_return(json_response(results: [ page(PAGE_ID, title: "Q3 plan") ], has_more: false))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      item = Feed.last

      assert_equal "pages/#{PAGE_ID}", item.locator_key
      assert_equal "Q3 plan", item.title
      assert_equal "text/markdown", item.mime
    end
  end

  test "one page looked up by its id is the page a sync would have made" do
    stub_request(:post, "#{API}/search")
      .to_return(json_response(results: [ page(PAGE_ID, title: "Q3 plan") ], has_more: false))
    stub_request(:get, "#{API}/pages/#{PAGE_ID}").to_return(json_response(page(PAGE_ID, title: "Q3 plan")))

    Tenant.switch(@tenant) do
      synced = nil
      @resource.each_page { |batch, _| synced = batch.first }

      assert_kept_as_synced(@resource, synced, @resource.object_for(PAGE_ID))
      assert_kept_as_synced(@resource, synced, @resource.object_for("pages/#{PAGE_ID}"))
    end
  end

  test "keeping a page catalogues it alone, and the next sync finds it rather than another" do
    stub_request(:get, "#{API}/pages/#{PAGE_ID}").to_return(json_response(page(PAGE_ID, title: "Q3 plan")))

    kept = Tenant.switch(@tenant) { @resource.command(:keep, id: PAGE_ID) }

    assert_not_requested :post, "#{API}/search"

    Tenant.switch(@tenant) do
      assert_equal "pages/#{PAGE_ID}", kept["key"]
      assert_equal "Q3 plan", kept["title"]
      assert_equal [ "keep" ], feed_at("pages/#{PAGE_ID}").analyses.map(&:cause)
    end

    edited = page(PAGE_ID, title: "Q3 plan").merge(last_edited_time: "2026-09-02T10:00:00.000Z")
    stub_request(:post, "#{API}/search").to_return(json_response(results: [ edited ], has_more: false))

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal kept["id"], feed_at("pages/#{PAGE_ID}").id.to_s
      assert Reference.find_by!(resource_id: @resource.id).changed_at.present?, "an edit after keeping is noticed"
    end
  end

  test "a database, a trashed page, or an id that is not one is neither kept nor read" do
    stub_request(:get, "#{API}/pages/#{PAGE_ID}").to_return(json_response(page(PAGE_ID).merge(in_trash: true)))

    Tenant.switch(@tenant) do
      assert_raises(Resource::Api::Gone) { @resource.command(:keep, id: PAGE_ID) }
      assert_raises(ArgumentError) { @resource.command(:keep, id: "../users/me") }
      assert_raises(ArgumentError) { @resource.command(:get, id: "../users/me") }
      assert_equal 0, Feed.count
    end
  end

  test "a page with nothing in its title property is Untitled rather than blank" do
    Tenant.switch(@tenant) do
      assert_equal "Untitled", @resource.title_for("id" => PAGE_ID, "properties" => {})
    end
  end

  test "an edited page is a new version" do
    Tenant.switch(@tenant) do
      assert_equal "2026-09-01T10:00:00.000Z",
                   @resource.version_for("last_edited_time" => "2026-09-01T10:00:00.000Z")
    end
  end

  test "downloading a page flattens its blocks into text a reader would recognise" do
    stub_blocks(PAGE_ID, [
      block("heading_1", "Q3 plan"),
      block("paragraph", "Ship the widget."),
      block("bulleted_list_item", "Tuesday"),
      block("to_do", "Tell Bea")
    ])

    text = Tenant.switch(@tenant) do
      @resource.download("id" => PAGE_ID, "title" => "Q3 plan").read
    end

    assert_match(/# Q3 plan/, text)
    assert_match(/Ship the widget\./, text)
    assert_match(/- Tuesday/, text)
    assert_match(/- \[ \] Tell Bea/, text)
  end

  test "a nested block is read, and the nesting stops before it can run away" do
    stub_blocks(PAGE_ID, [ block("paragraph", "Outer", id: "b1", children: true) ])
    stub_blocks("b1", [ block("paragraph", "Inner", id: "b2", children: true) ])
    stub_blocks("b2", [ block("paragraph", "Deeper", id: "b3", children: true) ])
    stub_blocks("b3", [ block("paragraph", "Deepest", id: "b4") ])

    text = Tenant.switch(@tenant) { @resource.download("id" => PAGE_ID).read }

    assert_match(/Outer/, text)
    assert_match(/Inner/, text)
    assert_not_requested :get, "#{API}/blocks/b3/children", query: hash_including({})
  end

  test "a block page that has gone leaves what was already read rather than failing the item" do
    stub_request(:get, "#{API}/blocks/#{PAGE_ID}/children")
      .with(query: hash_including({})).to_return(status: 404, body: "{}")

    text = Tenant.switch(@tenant) { @resource.download("id" => PAGE_ID, "title" => "Q3 plan").read }

    assert_equal "Q3 plan", text
  end

  test "nothing but api.notion.com is dialled" do
    Tenant.switch(@tenant) do
      assert_match(/is not Notion/,
                   assert_raises(Resource::Unusable) { @resource.api_get("https://evil.example.com/v1/users/me") }.message)
    end
  end

  private

    def page(id, title: "A page")
      {
        object: "page", id: id, url: "https://notion.so/#{id}",
        last_edited_time: "2026-09-01T10:00:00.000Z",
        properties: { "Name" => { type: "title", title: [ { plain_text: title } ] } }
      }
    end

    def database(id)
      { object: "database", id: id, last_edited_time: "2026-09-01T10:00:00.000Z" }
    end

    def block(type, text, id: SecureRandom.uuid, children: false)
      { object: "block", id: id, type: type, has_children: children,
        type => { rich_text: [ { plain_text: text } ] } }
    end

    def stub_blocks(id, blocks)
      stub_request(:get, "#{API}/blocks/#{id}/children")
        .with(query: hash_including({}))
        .to_return(json_response(results: blocks, has_more: false, next_cursor: nil))
    end
end
