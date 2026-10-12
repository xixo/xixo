require "test_helper"
require_relative "../support/machines"

class LinkingTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Machines

  LINK = <<~GQL.freeze
    mutation($key: String, $id: ID) {
      linkMachine(input: { key: $key, id: $id }) {
        resource { id key machine { linked selfLinked linkingUntil } }
        code
        expiresAt
      }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "linking-#{SecureRandom.hex(4)}", name: "Linking")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-amd64"), "x86 binary")
    File.binwrite(File.join(@binaries, "notes.txt"), "not a build")
    FileUtils.cp(Rails.root.join("link/xixo-link.service"), File.join(@binaries, "xixo-link.service"))
    FileUtils.cp(Rails.root.join("link/xixo-link.plist"), File.join(@binaries, "xixo-link.plist"))
    ENV["XIXO_LINK_DIR"] = @binaries
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    FileUtils.rm_rf(@binaries)
  end

  test "only an administrator links a machine" do
    body = graphql(Grant::SIGN_IN, LINK, key: "studio")

    assert_match(/only an administrator links a machine/, body.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_not Resource::Machine.exists? }
    assert_not issuer.enrollments.any? { |asked| asked["subdomain"] == @tenant.subdomain }
  end

  test "linking names a machine with no key, asks masks for a code, and keeps only its digest" do
    linked = nil

    assert_no_enqueued_jobs(only: InstallLinkJob) do
      linked = graphql(Grant::SCOPES, LINK, key: "studio").dig("data", "linkMachine")
    end

    assert_match(/\Aenroll-/, linked["code"])
    assert_in_delta 10.minutes.from_now, Time.iso8601(linked["expiresAt"]), 5
    assert_equal({ "linked" => false, "selfLinked" => true, "linkingUntil" => linked["expiresAt"] },
                 linked.dig("resource", "machine"))
    assert_equal "studio", issuer.enrollments.last["client_name"]

    Tenant.switch(@tenant) do
      machine = Resource::Machine.find_by!(key: "studio")
      assert_not_includes machine.details.to_json, linked["code"]
      assert machine.credentials.to_h.empty?
      assert_equal [ "bob" ], machine.operators
      assert machine.valid?
      error = assert_raises(Resource::Failed) { machine.check! }
      assert_match(/waiting for the machine to link up/, error.message)
    end
  end

  test "the code fetches xixo link and its service, and nothing else on the server" do
    code = link("studio")

    get "/link/download/xixo-link-linux-amd64", headers: bearer(code)
    assert_response :ok
    assert_equal "x86 binary", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
    Tenant.switch(@tenant) do
      assert_equal({ "file" => "xixo-link-linux-amd64" }, AuditEvent.where(channel: "link", action: "download", status: "ok").sole.arguments)
    end

    get "/link/download/xixo-link-linux-amd64", headers: bearer("enroll-#{'x' * 40}")
    assert_response :unauthorized

    get "/link/download/xixo-link-linux-amd64", headers: { "HOST" => host }
    assert_response :unauthorized

    get "/link/download/xixo-link.plist", headers: bearer(code)
    assert_response :ok
    assert_includes response.body, "<string>network.xixo.link</string>"

    get "/link/download/xixo-link.plist", headers: { "HOST" => host }
    assert_response :unauthorized

    get "/link/download/xixo-link-darwin-arm64", headers: bearer(code)
    assert_response :not_found

    [ "/link/download/notes.txt", "/link/download/..%2Fxixo-link.service", "/link/download/xixo-link-linux-amd64%2F..%2F..%2Fpasswd" ].each do |path|
      get path, headers: bearer(code)
      assert_includes [ 401, 404 ], response.status, path
      assert_not_equal "not a build", response.body
    end
  end

  test "the service comes filled in with the account and the folders, which are checked" do
    code = link("studio")

    get "/link/download/xixo-link.service", params: { user: "jon", folders: [ "/srv/media", "/data/My Photos" ] },
                                              headers: bearer(code)

    assert_response :ok
    assert_includes response.body, "User=jon\n"
    assert_includes response.body, %(BindReadOnlyPaths="-/srv/media" "-/data/My Photos"\n)

    get "/link/download/xixo-link.service", params: { user: "jon", folders: [ "/srv/media", "/srv/inbox:rw" ] },
                                              headers: bearer(code)

    assert_response :ok
    assert_includes response.body, %(BindReadOnlyPaths="-/srv/media"\nBindPaths="-/srv/inbox"\n)

    get "/link/download/xixo-link.service", params: { user: "jon; rm -rf /", folders: [ "/srv" ] }, headers: bearer(code)
    assert_response :unprocessable_content

    get "/link/download/xixo-link.service", params: { user: "jon", folders: [ "/srv/../etc" ] }, headers: bearer(code)
    assert_response :unprocessable_content
  end

  test "the machine names its client with the code once, and xixo lets that client in" do
    code = link("studio")

    link_up(code, client_id: "client-studio")
    assert_response :ok
    assert_match(/Linked up as studio/, response.body)
    Tenant.switch(@tenant) do
      linked = AuditEvent.where(channel: "link", action: "link").sole
      assert_equal [ "ok", "client", "client-studio" ], [ linked.status, linked.actor, linked.actor_name ]
    end

    Tenant.switch(@tenant) do
      machine = Resource::Machine.find_by!(key: "studio")
      assert_equal machine, Resource::Machine.enrolled("client-studio")
      assert_nil machine.details["linking"]
    end

    link_up(code, client_id: "client-other")
    assert_response :unauthorized
    Tenant.switch(@tenant) { assert_nil Resource::Machine.enrolled("client-other") }

    get "/link/download/xixo-link-linux-amd64", headers: bearer(code)
    assert_response :unauthorized
    Tenant.switch(@tenant) { assert_equal 2, AuditEvent.where(channel: "link", status: "denied").count }
  end

  test "a machine linked again as the client it already is uses up its code" do
    machine = machine_on(@tenant, key: "box", client_id: "client-box")
    code = graphql(Grant::SCOPES, LINK, id: machine.id).dig("data", "linkMachine", "code")

    link_up(code, client_id: "client-box")
    assert_response :ok
    Tenant.switch(@tenant) { assert_nil machine.reload.details["linking"] }

    link_up(code, client_id: "client-box")
    assert_response :unauthorized
  end

  test "a code links only its own machine and never takes a client another machine holds" do
    machine_on(@tenant, key: "box", client_id: "client-box")
    code = link("studio")

    link_up(code, client_id: "client-box")
    assert_response :unprocessable_content
    assert_match(/Another machine is linked as that client/, response.body)

    post "/link", params: { code: code, client_id: "client-studio" }, headers: bearer(code)
    assert_response :unauthorized
    assert_match(/takes the machine's own token/, response.body)

    Tenant.switch(@tenant) do
      assert_equal "client-box", Resource::Machine.find_by!(key: "box").client_id
      assert_nil Resource::Machine.find_by!(key: "studio").client_id
    end
  end

  test "a code runs out, and a fresh one replaces it" do
    first = link("studio")
    id = Tenant.switch(@tenant) { Resource::Machine.find_by!(key: "studio").id }
    second = graphql(Grant::SCOPES, LINK, id: id).dig("data", "linkMachine", "code")

    link_up(first, client_id: "client-studio")
    assert_response :unauthorized

    travel Resource::Machine::Linking::LINKED_WITHIN + 1.minute do
      link_up(second, client_id: "client-studio")
      assert_response :unauthorized

      Tenant.switch(@tenant) do
        error = assert_raises(Resource::Failed) { Resource::Machine.find(id).check! }
        assert_match(/has not linked up yet. Get a fresh code/, error.message)
      end
    end
  end

  test "linking a machine again replaces its client once the new one names itself" do
    machine = machine_on(@tenant, key: "box", client_id: "client-old")
    revoked = []
    code = graphql(Grant::SCOPES, LINK, id: machine.id).dig("data", "linkMachine", "code")

    Tenant.switch(@tenant) { assert_equal "client-old", machine.reload.client_id }

    held = Resource::Machine::Enrollment.method(:revoke)
    Resource::Machine::Enrollment.define_singleton_method(:revoke) { |_tenant, client_id| revoked << client_id }
    link_up(code, client_id: "client-new")
    assert_response :ok
    assert_equal [ "client-old" ], revoked
    Tenant.switch(@tenant) { assert_equal "client-new", machine.reload.client_id }
  ensure
    Resource::Machine::Enrollment.define_singleton_method(:revoke, held) if held
  end

  test "an administrator sees where a machine dials and the builds this server hands out" do
    body = graphql(Grant::SCOPES, "{ linkUp { xixo issuer builds { os arch file sha256 } } }")

    held = body.dig("data", "linkUp")
    assert_equal "http://#{host}", held["xixo"]
    assert_equal @tenant.issuer, held["issuer"]
    assert_equal [ { "os" => "linux", "arch" => "amd64", "file" => "xixo-link-linux-amd64",
                     "sha256" => Digest::SHA256.hexdigest("x86 binary") } ], held["builds"]

    assert_nil graphql(Grant::SIGN_IN, "{ linkUp { xixo } }").dig("data", "linkUp")
  end

  test "a Mac is pointed at the mac reader of the GitHub release of this server's version" do
    version = JSON.parse(Rails.root.join(".release-please-manifest.json").read)["."]

    held = graphql(Grant::SCOPES, "{ linkUp { macReader } }").dig("data", "linkUp")

    assert_equal "https://github.com/xixo/xixo/releases/download/server-v#{version}/xixo-mac-reader", held["macReader"]
  end

  private

    def link(key)
      graphql(Grant::SCOPES, LINK, key: key).dig("data", "linkMachine", "code")
    end

    def host
      "#{@tenant.subdomain}.xixo.test"
    end

    def link_up(code, client_id:)
      token = machine_token(@tenant, client_id: client_id)
      post "/link", params: { code: code }, headers: {
        "HOST" => host, "Authorization" => "DPoP #{token}",
        "DPoP" => dpop_proof(token, url: "http://#{host}/link", method: "POST")
      }
    end

    def bearer(code)
      { "HOST" => host, "Authorization" => "Bearer #{code}" }
    end

    def graphql(scopes, query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{host}/mcp")
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: { "HOST" => host, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }

      response.parsed_body
    end
end
