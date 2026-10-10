require "test_helper"

class GithubResourceTest < ActiveSupport::TestCase
  API = "https://api.github.com".freeze

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "gh-#{SecureRandom.hex(4)}", name: "GitHub")

    Tenant.switch(@tenant) do
      @resource = Resource::Github.create!(
        key: "github", name: "Work",
        details: { "repos" => "acme/widgets", "state" => "all" },
        credentials: { "token" => "github_pat_secret" }
      )
    end
  end

  test "the stored type is github and it loads back as the class" do
    assert_equal "github", @resource.type

    Tenant.switch(@tenant) { assert_instance_of Resource::Github, Resource.find(@resource.id) }
  end

  test "it syncs, and it is neither storage nor inference" do
    assert @resource.syncable?
    assert_not @resource.storage?
    assert_not @resource.inference?
  end

  test "a repository that is not owner/name is refused before anything is asked" do
    Tenant.switch(@tenant) do
      resource = Resource::Github.new(key: "bad", details: { "repos" => "widgets" },
                                      credentials: { "token" => "t" })

      assert_not resource.valid?
      assert_includes resource.errors[:details].join, "is not owner/name"
    end
  end

  test "naming no repository at all is refused too" do
    Tenant.switch(@tenant) do
      resource = Resource::Github.new(key: "bare", credentials: { "token" => "t" })

      assert_not resource.valid?
      assert_includes resource.errors[:details].join, "must name at least one repository"
    end
  end

  test "check passes when the token names an account that can read every repository" do
    stub_request(:get, "#{API}/user").to_return(json_response(login: "ash"))
    stub_request(:get, "#{API}/repos/acme/widgets").to_return(json_response(full_name: "acme/widgets"))

    Tenant.switch(@tenant) { assert @resource.check! }
  end

  test "check names the repository the token cannot reach, rather than only failing" do
    stub_request(:get, "#{API}/user").to_return(json_response(login: "ash"))
    stub_request(:get, "#{API}/repos/acme/widgets").to_return(status: 404, body: "{}")

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { @resource.check! } }

    assert_match(/acme\/widgets/, error.message)
    assert_match(/repository access/, error.message)
  end

  test "a token GitHub refuses says so rather than looking like an outage" do
    stub_request(:get, "#{API}/user").to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { @resource.check! } }

    assert_match(/refused the token/, error.message)
  end

  test "rate limiting is a failure worth retrying, not a broken resource" do
    stub_request(:get, "#{API}/user").to_return(status: 429, body: { message: "slow down" }.to_json)

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { @resource.check! }

      assert_not_kind_of Resource::Unusable, error
      assert_match(/rate limiting/, error.message)
    end
  end

  test "a sync walks every page of every repository and stops when one runs out" do
    stub_issues(page: 1, count: 100, from: 1)
    stub_issues(page: 2, count: 3, from: 101)

    seen = []

    Tenant.switch(@tenant) do
      @resource.each_page { |batch, cursor| seen << [ batch.length, cursor ] }
    end

    assert_equal [ [ 100, "acme/widgets#1" ], [ 3, "acme/widgets#2" ] ], seen
  end

  test "a sync resumes at the page after the cursor rather than starting over" do
    stub_issues(page: 2, count: 2, from: 101)

    seen = []

    Tenant.switch(@tenant) do
      @resource.each_page(cursor: "acme/widgets#1") { |batch, _| seen << batch.length }
    end

    assert_equal [ 2 ], seen
    assert_not_requested :get, "#{API}/repos/acme/widgets/issues",
                         query: hash_including({ "page" => "1" })
  end

  test "a later sync asks only for issues updated since shortly before the last one began" do
    stub_issues(page: 1, count: 1, from: 7)

    travel_to Time.utc(2026, 9, 13, 12, 0) do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    travel_to Time.utc(2026, 9, 13, 13, 0) do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    assert_requested :get, "#{API}/repos/acme/widgets/issues",
                     query: hash_including({ "since" => "2026-09-13T11:55:00Z" })
  end

  test "an issue lands as one item, keyed on its number and titled with its repository" do
    stub_issues(page: 1, count: 1, from: 7)
    stub_issues(page: 2, count: 0, from: 0)

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      item = Feed.last

      assert_equal "acme/widgets/issues/7", item.locator_key
      assert_equal "acme/widgets#7 Issue 7", item.title
      assert_equal "text/markdown", item.mime
      assert_equal "issue", item.locator["shape"]
    end
  end

  test "a pull request is keyed apart from an issue of the same number" do
    Tenant.switch(@tenant) do
      pull = { "repo" => "acme/widgets", "number" => 7, "pull_request" => { "url" => "…" } }

      assert_equal "acme/widgets/pull/7", @resource.locator_key_for(pull)
      assert_equal "pull", @resource.locator_for(pull)["shape"]
    end
  end

  test "an edited issue is a new version, so it is analyzed again" do
    Tenant.switch(@tenant) do
      assert_equal "2026-09-01T00:00:00Z", @resource.version_for("updated_at" => "2026-09-01T00:00:00Z")
      assert_nil @resource.version_for({})
    end
  end

  test "downloading an issue is its body and its discussion, not a page of HTML" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Widget jams", body: "It jams on Tuesdays.",
                      state: "open", user: { login: "ash" }))
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7/comments")
      .with(query: hash_including({}))
      .to_return(json_response([ { body: "Reproduced on 2.1.", user: { login: "bea" } } ]))

    text = Tenant.switch(@tenant) do
      @resource.download("repo" => "acme/widgets", "number" => 7).read
    end

    assert_match(/Widget jams/, text)
    assert_match(/It jams on Tuesdays/, text)
    assert_match(/bea said:/, text)
    assert_match(/Reproduced on 2\.1/, text)
  end

  test "get and list read only the repositories it was attached with" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command(:get, key: "evil/secrets/issues/1") }
      assert_raises(ArgumentError) { @resource.command(:get, key: "../../user/issues/1") }
      assert_raises(ArgumentError) { @resource.command(:list, repo: "evil/secrets") }
    end

    assert_not_requested :get, %r{#{API}/(repos/evil|user)}
  end

  test "a command reads one issue by its key" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Widget jams", body: "…", state: "open",
                      user: { login: "ash" }, html_url: "https://github.com/acme/widgets/issues/7"))
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7/comments")
      .with(query: hash_including({})).to_return(json_response([]))

    found = Tenant.switch(@tenant) { @resource.command(:get, key: "acme/widgets/issues/7") }

    assert_equal "Widget jams", found["title"]
    assert_equal "https://github.com/acme/widgets/issues/7", found["url"]
  end

  test "one issue looked up by its key is the issue a sync would have made" do
    stub_issues(page: 1, count: 1, from: 7)
    stub_issues(page: 2, count: 0, from: 0)
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Issue 7", state: "open",
                               html_url: "https://github.com/acme/widgets/issues/7",
                               updated_at: "2026-09-01T00:00:00Z", comments: 0))

    Tenant.switch(@tenant) do
      synced = nil
      @resource.each_page { |batch, _| synced ||= batch.first }

      assert_kept_as_synced(@resource, synced, @resource.object_for("acme/widgets/issues/7"))
      assert_kept_as_synced(@resource, synced, @resource.object_for("ACME/Widgets/issues/7"))
    end
  end

  test "keeping an issue catalogues it once, and a later sync finds the same one" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Issue 7", state: "open",
                               updated_at: "2026-09-01T00:00:00Z", comments: 0))
    stub_issues(page: 1, count: 1, from: 7)
    stub_issues(page: 2, count: 0, from: 0)

    kept = Tenant.switch(@tenant) { @resource.command(:keep, key: "acme/widgets/issues/7") }
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal "acme/widgets/issues/7", kept["key"]
      assert_equal 1, Feed.files.count
      assert_equal kept["id"], feed_at("acme/widgets/issues/7").id.to_s
    end
  end

  test "an issue from a repository or a state the resource does not read is not kept" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/8")
      .to_return(json_response(number: 8, title: "Closed", state: "closed"))

    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command(:keep, key: "evil/secrets/issues/1") }

      @resource.update!(details: @resource.details.merge("state" => "open"))

      assert_raises(ArgumentError) { @resource.command(:keep, key: "acme/widgets/issues/8") }
      assert_equal 0, Feed.count
    end

    assert_not_requested :get, "#{API}/repos/evil/secrets/issues/1"
  end

  test "an issue nobody replied to is not asked for its replies" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Widget jams", body: "…", state: "open",
                               user: { login: "ash" }))

    Tenant.switch(@tenant) do
      @resource.download("repo" => "acme/widgets", "number" => 7, "comments" => 0).read
    end

    assert_not_requested :get, "#{API}/repos/acme/widgets/issues/7/comments",
                         query: hash_including({})
  end

  test "an issue whose count the locator does not carry is still asked" do
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7")
      .to_return(json_response(number: 7, title: "Widget jams", body: "…", state: "open",
                               user: { login: "ash" }))
    stub_request(:get, "#{API}/repos/acme/widgets/issues/7/comments")
      .with(query: hash_including({})).to_return(json_response([]))

    Tenant.switch(@tenant) do
      @resource.download("repo" => "acme/widgets", "number" => 7).read
    end

    assert_requested :get, "#{API}/repos/acme/widgets/issues/7/comments",
                     query: hash_including({})
  end

  test "nothing but api.github.com is dialled, whatever a locator carries" do
    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Unusable) do
        @resource.api_get("https://evil.example.com/repos/acme/widgets")
      end

      assert_match(/is not GitHub/, error.message)
    end
  end

  test "the token travels in the header and never in the query" do
    stub_request(:get, "#{API}/user").to_return(json_response(login: "ash"))

    Tenant.switch(@tenant) { @resource.api_get("/user") }

    assert_requested :get, "#{API}/user" do |request|
      request.headers["Authorization"] == "Bearer github_pat_secret" &&
        !request.uri.to_s.include?("github_pat_secret")
    end
  end

  test "an answer larger than the limit is refused as it arrives" do
    stub_request(:get, "#{API}/user").to_return(json_response(login: "a" * 4096))

    stub_const(Resource::Api, :MAX_BYTES, 1024) do
      failed = Tenant.switch(@tenant) { assert_raises(Resource::Failed) { @resource.api_get("/user") } }

      assert_match(/api\.github\.com sent more than 1024 bytes/, failed.message)
    end
  end

  test "a refusal larger than the limit is refused the same way" do
    stub_request(:get, "#{API}/user").to_return(status: 403, body: "x" * 4096)

    stub_const(Resource::Api, :MAX_BYTES, 1024) do
      failed = Tenant.switch(@tenant) { assert_raises(Resource::Failed) { @resource.api_get("/user") } }

      assert_match(/sent more than 1024 bytes/, failed.message)
    end
  end

  test "bytes asked for with their own limit stop there" do
    stub_request(:get, "#{API}/raw").to_return(status: 200, body: "x" * 300)

    failed = Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @resource.api_bytes("/raw", max_bytes: 100) }
    end

    assert_match(/sent more than 100 bytes/, failed.message)
    assert_equal "x" * 300, Tenant.switch(@tenant) { @resource.api_bytes("/raw", max_bytes: 300) }
  end

  private

    def stub_issues(page:, count:, from:)
      issues = Array.new(count) do |index|
        number = from + index

        { number: number, title: "Issue #{number}", state: "open",
          html_url: "https://github.com/acme/widgets/issues/#{number}",
          updated_at: "2026-09-0#{(index % 9) + 1}T00:00:00Z", comments: 0 }
      end

      stub_request(:get, "#{API}/repos/acme/widgets/issues")
        .with(query: hash_including({ "page" => page.to_s }))
        .to_return(json_response(issues))
    end
end
