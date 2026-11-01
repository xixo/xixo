require "test_helper"
require_relative "../support/machines"

class LinkingTest < ActionDispatch::IntegrationTest
  include Machines

  APPROVE = <<~GQL.freeze
    mutation($id: ID!, $off: [String!]) { approveLinkRequest(input: { id: $id, off: $off }) { request { id status hostname code } } }
  GQL
  DENY = <<~GQL.freeze
    mutation($id: ID!) { denyLinkRequest(input: { id: $id }) { request { id status } } }
  GQL
  REQUESTS = "{ linkRequests { id code status hostname os arch folders writable remoteIp machine { key } } }".freeze
  PLAN = <<~GQL.freeze
    mutation($id: ID!, $key: String!, $on: Boolean!) {
      setMachinePlan(input: { id: $id, key: $key, on: $on }) {
        resource { machine { plan { key on possible } lends tools } }
      }
    }
  GQL
  UPDATES = <<~GQL.freeze
    mutation($id: ID, $action: String!) {
      requestMachineUpdate(input: { id: $id, action: $action }) { linkUpdates { machines { key machine { updates updateState } } } }
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
    File.binwrite(File.join(@binaries, "xixo-link-linux-riscv64"), "not a build")
    FileUtils.cp(Rails.root.join("link/xixo-link.service"), File.join(@binaries, "xixo-link.service"))
    FileUtils.cp(Rails.root.join("link/xixo-link.plist"), File.join(@binaries, "xixo-link.plist"))
    %w[xixo-link-fetch.service xixo-link-update.service xixo-link-update.path xixo-link-update.timer xixo-link-packages.service].each do |unit|
      FileUtils.cp(Rails.root.join("link", unit), File.join(@binaries, unit))
    end
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
    assert_not_includes response.body, "apt-get"
    assert_includes response.body, '"$work/xixo-link" up'
    assert_not_includes response.body, "enroll-"
  end

  test "the script hands the install to xixo link itself, as root on Linux, and starts it the same way" do
    get "/link.sh", headers: { "HOST" => host }

    assert_includes response.body, 'as_root "$work/xixo-link" install --xixo "$xixo" --issuer "$issuer" --user "$user" --from "$work/xixo-link" "$@"'
    assert_includes response.body, 'as_root "$work/xixo-link" start'
    assert_includes response.body, '"$work/xixo-link" install --xixo "$xixo" --issuer "$issuer" --from "$work/xixo-link" "$@"'
    assert_not_includes response.body, "useradd"
    assert_not_includes response.body, "systemctl enable"
    assert_not_includes response.body, "launchctl bootstrap"
  end

  test "a mac reader xixo holds is served from xixo" do
    FileUtils.mkdir_p(File.join(@binaries, "mac"))
    File.binwrite(File.join(@binaries, "mac", "xixo-mac-reader"), "mac reader")

    get "/link/download/xixo-mac-reader", headers: { "HOST" => host }
    assert_response :ok
    assert_equal "mac reader", response.body
  end

  test "the script quotes what it is given so a value cannot break out" do
    script = Resource::Machine::Script.new(xixo: "https://x.example/'; rm -rf ~; '", issuer: "https://id.example", builds: []).to_s

    assert_includes script, %(xixo='https://x.example/'\\''; rm -rf ~; '\\'''\n)
    assert_includes script, '*) fail "this xixo has no xixo link for $system on $arch. Ask the administrator of xixo to add that build." ;;'
  end

  test "the script parses, reads nothing from standard input, and says what each step does before it starts" do
    get "/link.sh", headers: { "HOST" => host }
    script = response.body

    Tempfile.create([ "link", ".sh" ]) do |file|
      file.write(script)
      file.flush
      assert system("sh", "-n", file.path), "the script does not parse"
    end

    assert_no_match(/(?:^|[;|&(]) *read\s|<&0|\bcat -/, script)
    assert_includes script, 'step "Downloading xixo link for $system on $arch."'
    assert_includes script, "sudo asks for your password to write to /usr/local/lib/xixo-link, /etc/xixo-link, and /etc/systemd/system."
    assert_includes script, 'step "Restarting xixo link with the new version. This can take up to 15 seconds."'
    assert_includes script, '"$work/xixo-link" status || true'
    assert_includes script, 'if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then'
    assert_operator script.index("sudo asks for your password"), :<, script.index("sudo -v")
  end

  test "a Mac whose xixo link can update itself gets the new build as an update, so Full Disk Access stays" do
    get "/link.sh", headers: { "HOST" => host }

    assert_includes response.body, %("$dir/bin/xixo-link" run -h 2>&1 | grep -q -- '-supervised')
    assert_includes response.body, 'step "Installing xixo link $version in $shown as an update."'
    assert_includes response.body, "Full Disk Access stays as it was"
    assert_includes response.body, 'say "     $shown/bin/xixo-link"'
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

    get "/link/download/xixo-link-update.service", headers: { "HOST" => host }
    assert_response :ok
    assert_includes response.body, "PrivateNetwork=yes"
    assert_equal "text/plain", response.media_type

    get "/link/download/xixo-link-update.path", headers: { "HOST" => host }
    assert_response :ok
    assert_includes response.body, "Unit=xixo-link-fetch.service"

    get "/link/download/xixo-link-update.timer", headers: { "HOST" => host }
    assert_response :ok
    assert_includes response.body, "OnUnitActiveSec=1d"

    get "/link/download/xixo-link-part@.service", headers: { "HOST" => host }
    assert_response :not_found

    get "/link/download/xixo-link-linux-arm64", headers: { "HOST" => host }
    assert_response :not_found

    get "/link/download/xixo-mac-reader", headers: { "HOST" => host }
    assert_response :not_found

    [ "/link/download/notes.txt", "/link/download/..%2Fxixo-link.service", "/link/download/xixo-link-linux-amd64%2F..%2F..%2Fpasswd",
      "/link/download/xixo-link-linux-riscv64" ].each do |path|
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
      "battery" => true, "readers" => [ "pdf", "shell", "text" ],
      "gpus" => [ { "maker" => "Apple", "model" => "Apple M2 Max", "memory" => 68_719_476_736, "driver" => "built in" }, { "maker" => "Acme" } ],
      "cpus_extra" => "ignored"
    }
    started = start(ASKED.merge("details" => details))
    machine_on(@tenant, key: "studio", client_id: "client-first")

    asked = graphql(Grant::SCOPES, <<~GQL, code: started["user_code"]).dig("data", "linkRequest")
      query($code: String!) {
        linkRequest(code: $code) {
          user system model version cpus memory addresses disks { path total free } services { kind port }
          battery readers gpus { maker model memory driver } plan { key says why on possible }
          sameAddress linksAs namedLike
        }
      }
    GQL

    assert_equal [ "jon", "macOS 26.0", "Mac14,7", "0.2.0", 10, "17179869184" ],
                 asked.values_at("user", "system", "model", "version", "cpus", "memory")
    assert_equal [ "192.168.1.20", "100.64.0.1" ], asked["addresses"]
    assert_equal [ { "path" => "/Users/jon/Desktop", "total" => "100", "free" => "100" } ], asked["disks"]
    assert_equal [ { "kind" => "ollama", "port" => 11434 } ], asked["services"]
    assert asked["battery"]
    assert_equal %w[pdf text], asked["readers"]
    assert_equal [ { "maker" => "Apple", "model" => "Apple M2 Max", "memory" => "68719476736", "driver" => "built in" } ], asked["gpus"]
    assert_equal [
      { "key" => "catalog", "says" => "Catalog Documents. Read and write Desktop.", "why" => nil, "on" => true, "possible" => true },
      { "key" => "extract", "says" => "Extract text from documents, and from files other machines lend it.", "why" => "It reads PDFs and text.", "on" => true, "possible" => true },
      { "key" => "models", "says" => "Use the Ollama already running on it.", "why" => "It answers on port 11434.", "on" => true, "possible" => true }
    ], asked["plan"]
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
    started = start
    graphql(Grant::SCOPES, APPROVE, id: request_id, off: [ "extract" ])
    poll(started)

    bind(started, client_id: "client-studio")
    assert_response :ok
    machine = Tenant.switch(@tenant) { Resource::Machine.enrolled("client-studio") }
    linked = { "name" => "studio", "key" => "studio", "url" => "http://#{host}/settings/resources/#{machine.id}", "updates" => true }
    assert_equal linked, response.parsed_body

    Tenant.switch(@tenant) do
      assert_equal [ "studio", "studio" ], [ machine.key, machine.name ]
      assert_not machine.details.key?("access")
      assert_equal [ "extract" ], machine.plan_off
      assert_equal [ "/Users/jon/Desktop", "/Users/jon/Documents" ], machine.about["folders"]
      assert_equal "Catalog Documents. Read and write Desktop.", machine.plan.first.says
      assert_not machine.reads_for_others?
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
    assert_equal linked, response.parsed_body

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

  test "an administrator turns a line of a machine's plan off, and nobody else does" do
    machine = machine_on(@tenant, key: "box")
    Tenant.switch(@tenant) { machine.update_columns(details: machine.details.deep_merge("machine" => { "extractors" => %w[pdf], "details" => { "readers" => %w[pdf] } })) }

    assert_match(/only an administrator changes what a machine does/,
                 graphql(Grant::SIGN_IN, PLAN, id: machine.id, key: "extract", on: false).dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert Resource::Machine.find(machine.id).reads_for_others? }

    held = graphql(Grant::SCOPES, PLAN, id: machine.id, key: "extract", on: false)
    assert_equal({ "key" => "extract", "on" => false, "possible" => true },
                 held.dig("data", "setMachinePlan", "resource", "machine", "plan").find { |line| line["key"] == "extract" })
    Tenant.switch(@tenant) do
      assert_not Resource::Machine.find(machine.id).reads_for_others?
      assert_equal [ "set_machine_plan", { "key" => "box", "line" => "extract", "on" => false } ],
                   AuditEvent.where(channel: "graphql").last.values_at(:action, :arguments)
    end

    assert_match(/the plan has no line shell/, graphql(Grant::SCOPES, PLAN, id: machine.id, key: "shell", on: true).dig("errors", 0, "message"))
  end

  test "an administrator pauses updates of xixo link on a machine, and nobody else does" do
    machine = machine_on(@tenant, key: "box")

    assert_match(/only an administrator steers updates of xixo link/,
                 graphql(Grant::SIGN_IN, UPDATES, id: machine.id, action: "pause").dig("errors", 0, "message"))

    held = graphql(Grant::SCOPES, UPDATES, id: machine.id, action: "pause")
    assert_equal({ "updates" => false, "updateState" => "manual" },
                 held.dig("data", "requestMachineUpdate", "linkUpdates", "machines").find { |said| said["key"] == "box" }["machine"])
    Tenant.switch(@tenant) do
      assert_not Resource::Machine.find(machine.id).updates?
      assert_equal [ "request_machine_update", { "key" => "box", "action" => "pause" } ],
                   AuditEvent.where(channel: "graphql").last.values_at(:action, :arguments)
    end
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
