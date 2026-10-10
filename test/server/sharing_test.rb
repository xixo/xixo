require "test_helper"

class SharingTest < ActionDispatch::IntegrationTest
  FROM_DEVICE = { "Sec-Fetch-Site" => "none", "Sec-Fetch-Mode" => "navigate" }.freeze

  setup do
    SearchIndex.reset!

    @forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    @tenant = Tenant.create!(subdomain: "share-#{SecureRandom.hex(4)}", name: "Sharing")
    @other = Tenant.create!(subdomain: "share-#{SecureRandom.hex(4)}", name: "Neighbour")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "blobs", name: "Storage")
      @storage.make_default_storage!
    end

    connect!(@tenant)
    connect!(@other)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "the manifest installs xixo and points its share target at this endpoint" do
    manifest = JSON.parse(Rails.public_path.join("manifest.webmanifest").read)
    target = manifest.fetch("share_target")
    routed = Rails.application.routes.recognize_path(target["action"], method: target["method"])

    assert_equal "xixo", manifest["name"]
    assert_equal "standalone", manifest["display"]
    assert_equal "/", manifest["start_url"]
    assert_equal({ controller: "shares", action: "create" }, routed)
    assert_equal "multipart/form-data", target["enctype"]
    assert_equal "files[]", target.dig("params", "files", 0, "name")

    manifest["icons"].each do |icon|
      assert Rails.public_path.join(icon["src"].delete_prefix("/")).file?, "#{icon['src']} is missing"
    end

    assert_equal %w[any maskable], manifest["icons"].map { |icon| icon["purpose"] }.uniq.sort
  end

  test "the layout links the manifest and a touch icon" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read

    assert_includes layout, %(<link rel="manifest" href="/manifest.webmanifest">)
    assert_includes layout, %(<link rel="apple-touch-icon" href="/apple-touch-icon.png" sizes="180x180">)
    assert Rails.public_path.join("apple-touch-icon.png").file?
  end

  test "a shared file is staged the way an upload is and opens on its item" do
    sign_in

    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      share files: [ uploaded("march.txt", "contents of march") ]
    end

    assert_response :see_other

    Tenant.switch(@tenant) do
      feed = Feed.files.sole

      assert feed.staged?
      assert_equal "/items/#{feed.id}?shared=kept", response.location.delete_prefix(origin)
      assert_match(%r{\Ashared/\d{8}T\d{6}-march\.txt\z}, feed.staged.path)
    end
  end

  test "two shared files with the same name are both kept" do
    sign_in

    share files: [ uploaded("image.jpg", "first photo"), uploaded("image.jpg", "second photo") ]

    assert_equal "/?kept=2&refused=0&shared=files&twins=0", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) { assert_equal 2, Feed.files.count }
  end

  test "a file shared again is answered as already there" do
    sign_in

    share files: [ uploaded("march.txt", "the same bytes") ]
    first = response.location
    share files: [ uploaded("march.txt", "the same bytes") ]

    assert_equal first.sub("kept", "twin"), response.location
    Tenant.switch(@tenant) { assert_equal 1, Feed.files.count }
  end

  test "a file with nowhere to go is refused and nothing is staged" do
    Tenant.switch(@tenant) { @storage.update!(archived_at: Time.current) }
    sign_in

    share files: [ uploaded("march.pdf", "contents") ]

    assert_equal "/?kept=0&refused=1&shared=files&twins=0", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) do
      assert_equal 0, Feed.files.count
      assert_equal 0, ActiveStorage::Blob.count
    end
  end

  test "shared text becomes a note under the title it was shared with" do
    sign_in

    share title: "Groceries", text: "milk\nbread"

    Tenant.switch(@tenant) do
      note = Feed.find_by!(title: "Groceries")

      assert_equal MimeType::NOTE, note.staged.mime
      assert_equal "/items/#{note.id}?shared=note", response.location.delete_prefix(origin)
    end
  end

  test "a shared link is rendered when there is something to render it with" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    Tenant.switch(@tenant) { Resource::Web.create!(key: "web", name: "The web") }
    sign_in

    assert_enqueued_jobs 1, only: SnapshotUrlJob do
      share title: "A page", text: "https://example.com/a"
    end

    assert_equal "/?shared=page", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) { assert_equal "https://example.com/a", Run.sole.selector["url"] }
  end

  test "a shared link to a file is fetched into storage" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    sign_in

    assert_enqueued_jobs 1, only: FetchUrlJob do
      share url: "https://example.com/march.pdf"
    end

    assert_equal "/?shared=download", response.location.delete_prefix(origin)
  end

  test "a shared link with nothing to render it is kept as a note" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"
    sign_in

    assert_no_enqueued_jobs only: [ SnapshotUrlJob, FetchUrlJob ] do
      share title: "Pelicans", url: "https://example.com/pelicans"
    end

    Tenant.switch(@tenant) do
      note = Feed.find_by!(title: "Pelicans")

      assert_equal "https://example.com/pelicans", note.staged.blob.download
    end
  end

  test "a shared link to a private address is kept as a note and never fetched" do
    Tenant.switch(@tenant) { Resource::Web.create!(key: "web", name: "The web") }
    sign_in

    assert_no_enqueued_jobs only: [ SnapshotUrlJob, FetchUrlJob ] do
      share url: "http://169.254.169.254/latest/meta-data/"
    end

    assert_match(%r{\A/items/\d+\?shared=note\z}, response.location.delete_prefix(origin))
    Tenant.switch(@tenant) { assert_equal 0, Run.count }
  end

  test "an empty share keeps nothing" do
    sign_in

    share

    assert_equal "/?shared=nothing", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a share posted from another site is refused" do
    sign_in

    share(text: "planted", headers: { "Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example" })

    assert_response :unprocessable_content
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a share posted from a neighbouring tenant is refused" do
    sign_in

    share(text: "planted", headers: { "Sec-Fetch-Site" => "same-site", "Origin" => "http://#{@other.subdomain}.xixo.test" })

    assert_response :unprocessable_content
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a browser that sends no fetch metadata must send this origin" do
    sign_in

    share(text: "unlabelled", headers: { "Sec-Fetch-Site" => nil, "Origin" => "https://evil.example" })
    assert_response :unprocessable_content

    share(text: "unlabelled", headers: { "Sec-Fetch-Site" => nil })
    assert_response :unprocessable_content

    share(text: "from here", headers: { "Sec-Fetch-Site" => nil, "Origin" => origin })
    assert_response :see_other
    Tenant.switch(@tenant) { assert_equal [ "from here" ], Feed.files.map(&:title) }
  end

  test "a device share that names another origin is refused" do
    sign_in

    share(text: "planted", headers: { "Origin" => "https://evil.example" })

    assert_response :unprocessable_content
  end

  test "a browser that has not signed in is sent to sign in and nothing is kept" do
    share text: "before signing in"

    assert_response :see_other
    assert_equal "/auth/?return_to=%2F", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a sign-in that may only read is told so and nothing is kept" do
    sign_in(scopes: %w[xixo:catalog:read])

    share text: "not allowed"

    assert_equal "/?shared=denied", response.location.delete_prefix(origin)
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a token minted for another tenant cannot share into this one" do
    token = issuer.mint(subdomain: @other.subdomain, scopes: Grant::SCOPES,
                        audience: "http://#{@other.subdomain}.xixo.test/mcp")

    share(text: "elsewhere", headers: { "Authorization" => "Bearer #{token}" })

    assert_response :unauthorized
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  private

    def share(headers: {}, **params)
      post "/share", params: params, headers: host.merge(FROM_DEVICE).merge(headers).compact
    end

    def uploaded(name, contents)
      file = Tempfile.new([ "share", File.extname(name) ])
      file.binmode
      file.write(contents)
      file.rewind

      Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: name)
    end

    def origin
      "http://#{@tenant.subdomain}.xixo.test"
    end

    def host
      { "HOST" => "#{@tenant.subdomain}.xixo.test" }
    end

    def sign_in(scopes: Grant::SCOPES)
      get "/auth", headers: host
      granted = issuer.authorize!(response.location, scopes: scopes)

      get "/auth/callback", params: { code: granted[:code], state: granted[:state] }, headers: host
    end
end
