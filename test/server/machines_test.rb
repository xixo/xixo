require "test_helper"
require_relative "../support/machines"

class MachinesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Machines

  ATTACH = <<~GQL.freeze
    mutation($settings: JSON, $personal: Boolean) {
      attachResource(input: { type: "xixo-agent", key: "box", name: "Box", settings: $settings, personal: $personal }) {
        resource { key settings heldCredentials machine { connected folders } }
      }
    }
  GQL

  SETTINGS = {
    "host" => "100.64.0.9", "user" => "jon", "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----",
    "folders" => "/srv/media\n/srv/My Photos\n"
  }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "machines-#{SecureRandom.hex(4)}", name: "Machines")
    connect!(@tenant)
  end

  test "only an administrator attaches a machine, and never as only theirs" do
    member = graphql(Grant::SIGN_IN, ATTACH, settings: SETTINGS)
    assert_match(/only an administrator/, member.dig("errors", 0, "message"))

    personal = graphql(Grant::SCOPES, ATTACH, settings: SETTINGS, personal: true)
    assert_match(/an administrator attaches for everyone/, personal.dig("errors", 0, "message"))

    Tenant.switch(@tenant) { assert_not Resource::XixoAgent.exists? }
    assert_no_enqueued_jobs(only: InstallAgentJob)
  end

  test "attaching a machine with a key starts an install, keeps the key out of sight, and splits folders by line" do
    attached = nil

    assert_enqueued_with(job: InstallAgentJob) do
      attached = graphql(Grant::SCOPES, ATTACH, settings: SETTINGS).dig("data", "attachResource", "resource")
    end

    assert_equal [ "/srv/media", "/srv/My Photos" ], attached.dig("settings", "folders")
    assert_not attached["settings"].key?("private_key")
    assert_equal [ "private_key" ], attached["heldCredentials"]
    assert_equal false, attached.dig("machine", "connected")

    Tenant.switch(@tenant) { assert_equal [ "install" ], Run.where(resource: Resource.find_by!(key: "box")).pluck(:kind) }
  end

  test "a machine's agent says what it shares, and its folders are offered to attach" do
    agent = agent_on(@tenant, folders: [ "/srv/media" ])

    body = graphql(Grant::SCOPES, <<~GQL)
      {
        resources { key machine { hostname connected folders } }
        discovered(via: "#{agent.key}") { hostName services { type address } address(type: "agent-folder") }
      }
    GQL

    listed = body.dig("data", "resources").find { |held| held["key"] == "box" }
    assert_equal({ "hostname" => "box", "connected" => true, "folders" => [ "/srv/media" ] }, listed["machine"])
    assert_equal [ { "hostName" => "media", "services" => [ { "type" => "agent-folder", "address" => "/srv/media" } ], "address" => nil } ],
                 body.dig("data", "discovered")
  end

  test "a folder attaches through the machine and is refused when the machine does not share it" do
    agent_on(@tenant, folders: [ "/srv/media" ])
    attach = <<~GQL
      mutation($settings: JSON) {
        attachResource(input: { type: "agent-folder", key: "media", settings: $settings, via: "box" }) {
          resource { key via }
        }
      }
    GQL

    refused = graphql(Grant::SCOPES, attach, settings: { "folder" => "/etc" })
    assert_match(%r{/etc is not one the agent on box shares}, refused.dig("errors", 0, "message"))

    attached = graphql(Grant::SCOPES, attach, settings: { "folder" => "/srv/media" })
    assert_equal({ "key" => "media", "via" => "box" }, attached.dig("data", "attachResource", "resource"))
  end

  private

    def graphql(scopes, query, **variables)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}",
                                  "Content-Type" => "application/json" }

      response.parsed_body
    end
end
