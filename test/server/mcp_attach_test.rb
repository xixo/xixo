require "test_helper"

class McpAttachTest < ActionDispatch::IntegrationTest
  include McpClient

  COMMAND = %w[xixo:resources:read xixo:resources:command].freeze
  ADMIN = (COMMAND + %w[xixo:settings:admin]).freeze

  setup do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @tenant = Tenant.create!(subdomain: "attach-mcp-#{SecureRandom.hex(4)}", name: "Attaching")

    Tenant.switch(@tenant) { Resource::Tailnet.create!(key: "tailnet", name: "Tailnet") }
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "types lists what can be attached, with every credential marked and none of their values" do
    listed = tool(@tenant, %w[xixo:resources:read], "resource", do: "types")

    assert_equal [ "tailnet" ], listed["transports"]

    bucket = listed["types"].find { |held| held["type"] == "s3" }
    secret = bucket["fields"].find { |field| field["name"] == "secret_access_key" }

    assert bucket["routable"]
    assert secret["credential"]
    assert_not secret.key?("value")
    refute_includes listed["types"].map { |held| held["type"] }, "tailnet"
  end

  test "a type with no credential is attached through a transport, and checked" do
    attached = tool(@tenant, ADMIN, "resource", do: "attach", key: "ollama-mac", input: {
      type: "openai-compatible", via: "tailnet",
      settings: { base_url: "http://100.64.0.1:11434/v1", "models.fast": "gemma3:4b" }
    })

    assert_equal "ollama-mac", attached["key"]
    assert_equal "tailnet", attached["via"]
    assert_equal false, attached["healthy"]
    assert_match(/reached through tailnet, which is down/, attached["error"])

    Tenant.switch(@tenant) do
      held = Resource.find_by!(key: "ollama-mac")

      assert_equal "http://100.64.0.1:11434/v1", held.details["base_url"]
      assert_equal "tailnet", held.via.key
    end
  end

  test "a credential handed to attach is refused, and nothing is attached" do
    reply = call(@tenant, ADMIN, "tools/call", name: "resource", arguments: {
      do: "attach", key: "bucket",
      input: { type: "s3", settings: { endpoint: "https://s3.example.test", access_key_id: "id", secret_access_key: "hunter2" } }
    })

    assert reply.dig("result", "isError")
    assert_match(/credentials never travel through here/, reply.dig("result", "content", 0, "text"))
    assert_includes reply.dig("result", "content", 0, "text"), "/settings/resources"
    Tenant.switch(@tenant) { assert_nil Resource.find_by(key: "bucket") }
  end

  test "a type that always needs a credential is sent to the app before anything is tried" do
    reply = call(@tenant, ADMIN, "tools/call", name: "resource", arguments: {
      do: "attach", key: "bucket", input: { type: "s3", settings: { endpoint: "https://s3.example.test" } }
    })

    assert reply.dig("result", "isError")
    assert_match(/s3 takes access_key_id, secret_access_key/, reply.dig("result", "content", 0, "text"))
  end

  test "the credential never reaches the audit trail, even on a refused call" do
    call(@tenant, ADMIN, "tools/call", name: "resource", arguments: {
      do: "attach", key: "bucket",
      input: { type: "s3", settings: { endpoint: "https://s3.example.test", access_key_id: "id", secret_access_key: "hunter2" } }
    })

    Tenant.switch(@tenant) do
      refute AuditEvent.where(channel: "mcp").any? { |event| event.arguments.to_json.include?("hunter2") }
    end
  end

  test "attaching takes the command scope" do
    read = call(@tenant, %w[xixo:resources:read], "tools/call", name: "resource", arguments: {
      do: "attach", key: "ollama-mac", input: { type: "openai-compatible", settings: { base_url: "http://100.64.0.1:11434/v1" } }
    })

    assert read.dig("result", "isError") || read["error"]
    Tenant.switch(@tenant) { assert_nil Resource.find_by(key: "ollama-mac") }
  end

  test "a place everyone shares is attached only by an administrator" do
    reply = call(@tenant, COMMAND, "tools/call", name: "resource", arguments: {
      do: "attach", key: "ollama-mac", input: { type: "openai-compatible", settings: { base_url: "http://100.64.0.1:11434/v1" } }
    })

    assert_match(/only an administrator attaches a place everyone shares/, reply.dig("result", "content", 0, "text"))
    Tenant.switch(@tenant) { assert_nil Resource.find_by(key: "ollama-mac") }
  end

  test "anyone with the command scope attaches a place that is only theirs" do
    attached = tool(@tenant, COMMAND, "resource", do: "attach", key: "ollama-mine", input: {
      type: "openai-compatible", personal: true, settings: { base_url: "http://100.64.0.1:11434/v1" }
    })

    assert_equal "ollama-mine", attached["key"]
    Tenant.switch(@tenant) { assert Resource.find_by!(key: "ollama-mine").personal? }
  end

  test "a transport that is not here is refused" do
    reply = call(@tenant, ADMIN, "tools/call", name: "resource", arguments: {
      do: "attach", key: "ollama-mac",
      input: { type: "openai-compatible", via: "elsewhere", settings: { base_url: "http://100.64.0.1:11434/v1" } }
    })

    assert_match(/elsewhere is not a transport here/, reply.dig("result", "content", 0, "text"))
  end
end
