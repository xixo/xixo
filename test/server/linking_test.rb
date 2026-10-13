require "test_helper"
require_relative "../support/machines"

class LinkingTest < ActionDispatch::IntegrationTest
  include Machines

  APPROVE = <<~GQL.freeze
    mutation($id: ID!) { approveLinkRequest(input: { id: $id }) { request { id status hostname code } } }
  GQL
  DENY = <<~GQL.freeze
    mutation($id: ID!) { denyLinkRequest(input: { id: $id }) { request { id status } } }
  GQL
  REQUESTS = "{ linkRequests { id code status hostname os arch folders writable remoteIp machine { key } } }".freeze
  ACCESS = <<~GQL.freeze
    mutation($id: ID!, $access: String, $helpsOthers: Boolean) {
      setMachineAccess(input: { id: $id, access: $access, helpsOthers: $helpsOthers }) {
        resource { machine { access helpsOthers lends tools extractsForOthers } }
      }
    }
  GQL
  ASKED = { "hostname" => "Studio.local", "os" => "darwin", "arch" => "arm64",
            "folders" => [ "/Users/jon/Documents", "/Users/jon/Desktop", "relative" ], "writable" => [ "/Users/jon/Desktop", "/etc" ] }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "linking-#{SecureRandom.hex(4)}", name: "Linking")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-amd64"), "x86 binary")
    File.binwrite(File.join(@binaries, "xixo-link-darwin-arm64"), "mac binary")
    File.binwrite(File.join(@binaries, "notes.txt"), "not a build")
    FileUtils.cp(Rails.root.join("link/xixo-link.service"), File.join(@binaries, "xixo-link.service"))
    FileUtils.cp(Rails.root.join("link/xixo-link.plist"), File.join(@binaries, "xixo-link.plist"))
    ENV["XIXO_LINK_DIR"] = @binaries
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    FileUtils.rm_rf(@binaries)
  end

  test "the link-up script is public, carries no secret, and pins each build's checksum" do
    get "/link.sh", headers: { "HOST" => host }

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match %r{\A#!/bin/sh\nset -eu\n}, response.body
    assert_includes response.body, "xixo='http://#{host}'"
    assert_includes response.body, "issuer='#{@tenant.issuer}'"
    assert_includes response.body, "linux-amd64) sum=#{Digest::SHA256.hexdigest('x86 binary')} ;;"
    assert_includes response.body, "darwin-arm64) sum=#{Digest::SHA256.hexdigest('mac binary')} ;;"
    assert_not_includes response.body, "linux-arm64)"
    assert_includes response.body, Resource::Machine::Downloads::PACKAGES.join(" ")
    assert_includes response.body, "xixo-link up"
    assert_not_includes response.body, "enroll-"
  end

  test "the script quotes what it is given so a value cannot break out" do
    script = Resource::Machine::Script.new(xixo: "https://x.example/'; rm -rf ~; '", issuer: "https://id.example", builds: [], mac_reader: nil).to_s

    assert_includes script, %(xixo='https://x.example/'\\''; rm -rf ~; '\\'''\n)
    assert_includes script, "reader=''\n"
    assert_includes script, '*) fail "this xixo has no xixo link for $os on $arch." ;;'
  end

  test "the builds, the service, and the launch agent download without a secret, and nothing else does" do
    get "/link/download/xixo-link-linux-amd64", headers: { "HOST" => host }
    assert_response :ok
    assert_equal "x86 binary", response.body

    get "/link/download/xixo-link.service", headers: { "HOST" => host }
    assert_response :ok
    assert_includes response.body, "User=@USER@"

    get "/link/download/xixo-link.plist", headers: { "HOST" => host }
    assert_response :ok
    assert_includes response.body, "<string>network.xixo.link</string>"

    get "/link/download/xixo-link-linux-arm64", headers: { "HOST" => host }
    assert_response :not_found

    [ "/link/download/notes.txt", "/link/download/..%2Fxixo-link.service", "/link/download/xixo-link-linux-amd64%2F..%2F..%2Fpasswd" ].each do |path|
      get path, headers: { "HOST" => host }
      assert_not_equal "not a build", response.body, path
    end
  end

  test "a machine asks to link up and gets a short code to show and a separate secret to poll with" do
    started = start

    assert_response :created
    assert_match(/\A[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}\z/, started["user_code"])
    assert_equal "http://#{host}/link/#{started['user_code']}", started["verification_uri_complete"]
    assert_equal 600, started["expires_in"]
    assert_equal 5, started["interval"]
    assert_operator started["device_code"].length, :>=, 43

    Tenant.switch(@tenant) do
      held = LinkRequest.sole
      assert_equal [ "studio.local", "darwin", "arm64" ], [ held.hostname, held.os, held.arch ]
      assert_equal [ "/Users/jon/Desktop", "/Users/jon/Documents" ], held.folders
      assert_equal [ "/Users/jon/Desktop" ], held.writable
      assert_not_includes held.attributes.to_json, started["device_code"]
      assert_not Resource::Machine.exists?
    end
  end

  test "a request carries what the machine says about itself, cleaned and bounded" do
    details = {
      "user" => "jon\u0007", "system" => "macOS 26.0", "model" => "Mac14,7", "version" => "0.2.0", "cpus" => 10,
      "memory" => 17_179_869_184, "addresses" => [ "192.168.1.20", "100.64.0.1", "not an address" ] * 10,
      "disks" => [ { "path" => "/Users/jon/Desktop", "total" => 100, "free" => 400 }, { "path" => "/etc", "total" => 1, "free" => 1 },
                   { "path" => "/Users/jon/Documents", "total" => "lots", "free" => 1 } ],
      "services" => [ { "kind" => "ollama", "port" => 11434 }, { "kind" => "shell", "port" => 22 } ],
      "cpus_extra" => "ignored"
    }
    started = start(ASKED.merge("details" => details))
    machine_on(@tenant, key: "studio", client_id: "client-first")

    asked = graphql(Grant::SCOPES, <<~GQL, code: started["user_code"]).dig("data", "linkRequest")
      query($code: String!) {
        linkRequest(code: $code) {
          user system model version cpus memory addresses disks { path total free } services { kind port }
          sameAddress linksAs namedLike
        }
      }
    GQL

    assert_equal [ "jon", "macOS 26.0", "Mac14,7", "0.2.0", 10, "17179869184" ],
                 asked.values_at("user", "system", "model", "version", "cpus", "memory")
    assert_equal [ "192.168.1.20", "100.64.0.1" ], asked["addresses"]
    assert_equal [ { "path" => "/Users/jon/Desktop", "total" => "100", "free" => "100" } ], asked["disks"]
    assert_equal [ { "kind" => "ollama", "port" => 11434 } ], asked["services"]
    assert asked["sameAddress"]
    assert_equal [ "studio-2", "studio" ], asked.values_at("linksAs", "namedLike")
  end

  test "a request from an older xixo link without details still shows" do
    started = start(ASKED.merge("details" => "nonsense"))

    asked = graphql(Grant::SCOPES, "query($code: String!) { linkRequest(code: $code) { user disks { path } addresses linksAs namedLike } }",
                    code: started["user_code"]).dig("data", "linkRequest")

    assert_equal({ "user" => nil, "disks" => [], "addresses" => [], "linksAs" => "studio", "namedLike" => nil }, asked)
  end

  test "one address waits on at most three machines at a time" do
    3.times { start }
    start

    assert_response :too_many_requests
    assert_equal "slow_down", response.parsed_body["error"]
  end

  test "polling waits for an administrator, slows down a machine that asks too often, and hands the token once" do
    started = start

    poll(started)
    assert_response :bad_request
    assert_equal "authorization_pending", response.parsed_body["error"]

    poll(started)
    assert_equal "slow_down", response.parsed_body["error"]

    assert_match(/only an administrator approves a machine/, graphql(Grant::SIGN_IN, APPROVE, id: request_id).dig("errors", 0, "message"))
    approved = graphql(Grant::SCOPES, APPROVE, id: request_id).dig("data", "approveLinkRequest", "request")
    assert_equal "approved", approved["status"]
    assert_equal "studio.local", issuer.enrollments.last["client_name"]

    travel 6.seconds do
      poll(started)
      assert_response :ok
      assert_match(/\Aenroll-/, response.parsed_body["enrollment_token"])
      assert_equal "studio.local", response.parsed_body["name"]
      Tenant.switch(@tenant) { assert_nil LinkRequest.sole.enrollment_token }
    end

    travel 12.seconds do
      poll(started)
      assert_equal "expired_token", response.parsed_body["error"]
    end
  end

  test "a denied machine hears so, and a request runs out after ten minutes" do
    denied = start
    graphql(Grant::SCOPES, DENY, id: request_id)
    poll(denied)
    assert_equal "access_denied", response.parsed_body["error"]

    waiting = start
    travel LinkRequest::LASTS + 1.second do
      poll(waiting)
      assert_equal "expired_token", response.parsed_body["error"]
    end

    post "/link/requests/token", params: { device_code: "made-up" }, headers: { "HOST" => host }
    assert_equal "expired_token", response.parsed_body["error"]
  end

  test "only an administrator sees who is asking to link up" do
    started = start

    assert_empty graphql(Grant::SIGN_IN, REQUESTS).dig("data", "linkRequests")
    listed = graphql(Grant::SCOPES, REQUESTS).dig("data", "linkRequests").sole
    assert_equal [ "studio.local", "pending", started["user_code"], "127.0.0.1" ], listed.values_at("hostname", "status", "code", "remoteIp")

    by_code = graphql(Grant::SCOPES, "query($code: String!) { linkRequest(code: $code) { hostname } }",
                      code: started["user_code"].downcase.delete("-"))
    assert_equal "studio.local", by_code.dig("data", "linkRequest", "hostname")
    assert_nil graphql(Grant::SIGN_IN, "query($code: String!) { linkRequest(code: $code) { hostname } }",
                       code: started["user_code"]).dig("data", "linkRequest")
  end

  test "the approved machine binds its own client once, and shows up named from its hostname" do
    started = approved_and_handed

    bind(started, client_id: "client-studio")
    assert_response :ok
    assert_equal "Linked up as studio.\n", response.body

    Tenant.switch(@tenant) do
      machine = Resource::Machine.enrolled("client-studio")
      assert_equal [ "studio", "studio" ], [ machine.key, machine.name ]
      assert_equal "search", machine.access
      assert machine.helps_others?
      assert_equal [ "bob" ], machine.operators
      assert_equal "linked", LinkRequest.sole.status
      assert_equal machine, LinkRequest.sole.resource
      assert_equal [ "ok", "client", "client-studio" ], AuditEvent.where(channel: "link", action: "link").sole.values_at(:status, :actor, :actor_name)
    end

    bind(started, client_id: "client-other")
    assert_response :unprocessable_content
    Tenant.switch(@tenant) { assert_nil Resource::Machine.enrolled("client-other") }

    get "/link", headers: signed("client-studio", method: "GET")
    assert_response :ok
    assert_equal "Linked up as studio.\n", response.body

    get "/link", headers: signed("client-unknown", method: "GET")
    assert_response :not_found
  end

  test "a request binds only once handed, only with the machine's own token, and never a client another machine holds" do
    started = start
    bind(started, client_id: "client-studio")
    assert_response :unprocessable_content

    machine_on(@tenant, key: "box", client_id: "client-box")
    started = approved_and_handed
    bind(started, client_id: "client-box")
    assert_response :unprocessable_content
    assert_match(/Another machine is linked as that client/, response.body)

    post "/link", params: { device_code: started["device_code"] }, headers: { "HOST" => host }
    assert_response :unauthorized

    bind({ "device_code" => "made-up" }, client_id: "client-studio")
    assert_response :unauthorized

    Tenant.switch(@tenant) { assert_equal [ "box" ], Resource::Machine.pluck(:key) }
  end

  test "a second machine with the same hostname gets a key of its own" do
    machine_on(@tenant, key: "studio", client_id: "client-first")

    bind(approved_and_handed, client_id: "client-second")

    Tenant.switch(@tenant) { assert_equal "studio-2", Resource::Machine.enrolled("client-second").key }
  end

  test "an administrator changes what xixo may do with a machine, and nobody else does" do
    machine = machine_on(@tenant, key: "box")

    assert_match(/only an administrator changes what xixo may do/,
                 graphql(Grant::SIGN_IN, ACCESS, id: machine.id, access: "files").dig("errors", 0, "message"))
    assert_match(/everything is not search, files, or writing/,
                 graphql(Grant::SCOPES, ACCESS, id: machine.id, access: "everything").dig("errors", 0, "message"))

    held = graphql(Grant::SCOPES, ACCESS, id: machine.id, access: "writing", helpsOthers: false)
    assert_equal({ "access" => "writing", "helpsOthers" => false }, held.dig("data", "setMachineAccess", "resource", "machine").slice("access", "helpsOthers"))
    Tenant.switch(@tenant) { assert_equal "set_machine_access", AuditEvent.where(channel: "graphql").last.action }
  end

  test "an administrator sees where the command fetches the script and which systems it serves" do
    held = graphql(Grant::SCOPES, "{ linkUp { xixo systems } }").dig("data", "linkUp")

    assert_equal({ "xixo" => "http://#{host}", "systems" => %w[darwin linux] }, held)
    assert_nil graphql(Grant::SIGN_IN, "{ linkUp { xixo } }").dig("data", "linkUp")
  end

  test "a machine is not attached by hand" do
    body = graphql(Grant::SCOPES, <<~GQL, settings: {})
      mutation($settings: JSON) { attachResource(input: { type: "machine", key: "box", settings: $settings }) { resource { id } } }
    GQL

    assert_match(/a machine links itself up/, body.dig("errors", 0, "message"))
  end

  private

    def start(said = ASKED)
      post "/link/requests", params: said.to_json, headers: { "HOST" => host, "Content-Type" => "application/json" }
      response.parsed_body
    end

    def poll(started)
      post "/link/requests/token", params: { device_code: started["device_code"] }, headers: { "HOST" => host }
    end

    def request_id
      Tenant.switch(@tenant) { LinkRequest.order(:id).last.id }
    end

    def approved_and_handed
      started = start
      graphql(Grant::SCOPES, APPROVE, id: request_id)
      poll(started)
      started
    end

    def bind(started, client_id:)
      post "/link", params: { device_code: started["device_code"] }, headers: signed(client_id)
    end

    def signed(client_id, method: "POST")
      token = machine_token(@tenant, client_id: client_id)
      { "HOST" => host, "Authorization" => "DPoP #{token}", "DPoP" => dpop_proof(token, url: "http://#{host}/link", method: method) }
    end

    def host
      "#{@tenant.subdomain}.xixo.test"
    end

    def graphql(scopes, query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{host}/mcp")
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: { "HOST" => host, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }

      response.parsed_body
    end
end
