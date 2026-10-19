require "test_helper"
require_relative "../support/machines"

class LinkMachinesTest < ActionDispatch::IntegrationTest
  include Machines

  DESCRIBED = {
    "hostname" => "media", "os" => "linux", "arch" => "amd64",
    "folders" => [ "/srv/media", "/srv/inbox" ], "writable" => [ "/srv/inbox" ],
    "details" => { "user" => "jon", "system" => "Ubuntu 26.04", "kind" => "desktop", "cpus" => 16, "memory" => 32_000_000_000,
                   "readers" => %w[pdf text], "services" => [ { "kind" => "ollama", "port" => 11434 } ],
                   "gpus" => [ { "maker" => "NVIDIA", "model" => "GTX 1070", "memory" => 8_589_934_592, "driver" => "580.178.04" } ] }
  }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "add-#{SecureRandom.hex(4)}", name: "Add")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-amd64"), "x86 binary")
    File.write(File.join(@binaries, "version"), "0.3.0+1a2b3c4\n")
    ENV["XIXO_LINK_DIR"] = @binaries
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    FileUtils.rm_rf(@binaries)
  end

  test "the builds xixo serves are listed with their checksums and version, without a secret" do
    get "/link/builds", headers: { "HOST" => host }

    assert_response :ok
    assert_equal [ { "os" => "linux", "arch" => "amd64", "sha256" => Digest::SHA256.hexdigest("x86 binary"), "version" => "0.3.0+1a2b3c4" } ],
                 response.parsed_body
  end

  test "an administrator adds a machine from its description, gets its plan and a token at once, and the machine binds with the device code" do
    post "/link/machines", params: DESCRIBED.merge("off" => [ "models" ]).to_json, headers: admin
    assert_response :created

    added = response.parsed_body
    assert_match(/\Aenroll-/, added["enrollment_token"])
    assert_equal [ "media", "media", "http://#{host}/settings/resources", @tenant.issuer ], added.values_at("name", "links_as", "url", "issuer")
    assert_equal [ %w[catalog true], %w[extract true], %w[models false] ],
                 added["plan"].map { |line| [ line["key"], line["on"].to_s ] }
    assert_equal "Catalog media. Read and write inbox.", added["plan"].first["says"]
    assert_equal "media", issuer.enrollments.last["client_name"]

    Tenant.switch(@tenant) do
      held = LinkRequest.sole
      assert_equal [ "handed", "bob", [ "models" ] ], [ held.status, held.decided_by, held.off ]
      assert_nil held.enrollment_token
      assert_equal [ "add", "ok" ], AuditEvent.where(channel: "link").last.values_at(:action, :status)
    end

    post "/link", params: { device_code: added["device_code"] }, headers: signed("client-media")
    assert_response :ok

    Tenant.switch(@tenant) do
      machine = Resource::Machine.enrolled("client-media")
      assert_equal [ "media", [ "bob" ], [ "models" ] ], [ machine.key, machine.operators, machine.plan_off ]
      assert_equal %w[pdf text], machine.about["readers"]
    end
  end

  test "adding a machine that is linked already keeps its place in xixo and replaces its client" do
    machine = machine_on(@tenant, key: "media", client_id: "client-old", operators: [ "alice" ])

    post "/link/machines", params: DESCRIBED.merge("key" => "media").to_json, headers: admin
    assert_response :created
    added = response.parsed_body
    assert_equal "media", added["links_as"]

    post "/link", params: { device_code: added["device_code"] }, headers: signed("client-new")
    assert_response :ok

    Tenant.switch(@tenant) do
      relinked = Resource::Machine.enrolled("client-new")
      assert_equal [ machine.id, "media", [ "alice" ], "bob" ], [ relinked.id, relinked.key, relinked.operators, relinked.details.dig("approved", "by") ]
      assert_equal %w[pdf text], relinked.about["readers"]
      assert_nil Resource::Machine.enrolled("client-old")
      assert_equal 1, Resource::Machine.active.where(key: "media").count
    end

    assert_equal "client-old", issuer.unenrollments.last["machine"]

    post "/link/machines", params: DESCRIBED.merge("key" => "attic").to_json, headers: admin
    assert_response :unprocessable_content
    assert_match(/no machine is linked as attic/, response.parsed_body["error_description"])
  end

  test "a machine is added only by an administrator with a token, and a plan line that does not exist is refused" do
    post "/link/machines", params: DESCRIBED.to_json, headers: { "HOST" => host, "Content-Type" => "application/json" }
    assert_response :unauthorized

    post "/link/machines", params: DESCRIBED.to_json, headers: admin(scopes: Grant::SIGN_IN)
    assert_response :forbidden
    assert_match(/only an administrator adds a machine/i, response.parsed_body["error_description"])

    post "/link/machines", params: DESCRIBED.merge("off" => [ "shell" ]).to_json, headers: admin
    assert_response :unprocessable_content
    assert_match(/the plan has no line shell/, response.parsed_body["error_description"])

    Tenant.switch(@tenant) { assert_equal 0, LinkRequest.count }
  end

  test "an administrator removes a machine, which puts it away and unenrolls its client" do
    machine = machine_on(@tenant, key: "attic", client_id: "client-attic")

    delete "/link/machines/attic", headers: admin(scopes: Grant::SIGN_IN)
    assert_response :forbidden

    delete "/link/machines/attic", headers: admin
    assert_response :no_content
    assert_equal "client-attic", issuer.unenrollments.last["machine"]
    Tenant.switch(@tenant) { assert Resource::Machine.find(machine.id).archived_at.present? }

    delete "/link/machines/attic", headers: admin
    assert_response :not_found
  end

  test "the command line signs a person in through the device grant that xixo starts and polls for it" do
    post "/link/cli/device", headers: { "HOST" => host }
    assert_response :ok
    assert_includes issuer.registrations.dig("items-test-client", "grant_types"), Masks::Client::Device::GRANT_TYPE
    device = response.parsed_body
    assert_match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/, device["user_code"])
    assert_includes device["verification_uri_complete"], device["user_code"]

    post "/link/cli/token", params: { device_code: device["device_code"] }, headers: { "HOST" => host }
    assert_response :bad_request
    assert_equal "authorization_pending", response.parsed_body["error"]

    issuer.approve_device!(device["user_code"])

    post "/link/cli/token", params: { device_code: device["device_code"] }, headers: { "HOST" => host }
    assert_response :ok
    tokens = response.parsed_body
    assert_equal "Bearer", tokens["token_type"]
    assert_match(/\Arefresh-/, tokens["refresh_token"])

    post "/link/machines", params: DESCRIBED.to_json,
                           headers: { "HOST" => host, "Content-Type" => "application/json", "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_response :created

    post "/link/cli/token", params: { refresh_token: tokens["refresh_token"] }, headers: { "HOST" => host }
    assert_response :ok
    assert_not_equal tokens["access_token"], response.parsed_body["access_token"]

    post "/link/cli/token", params: { device_code: "made-up" }, headers: { "HOST" => host }
    assert_response :unauthorized
  end

  private

    def host
      "#{@tenant.subdomain}.xixo.test"
    end

    def admin(scopes: Grant::SCOPES)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes, audience: "http://#{host}/mcp")
      { "HOST" => host, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    end

    def signed(client_id)
      token = machine_token(@tenant, client_id: client_id)
      { "HOST" => host, "Authorization" => "DPoP #{token}", "DPoP" => dpop_proof(token, url: "http://#{host}/link", method: "POST") }
    end
end
