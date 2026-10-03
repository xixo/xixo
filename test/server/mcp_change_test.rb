require "test_helper"
require_relative "../support/fake_model_server"

class McpChangeTest < ActionDispatch::IntegrationTest
  include McpClient

  COMMAND = %w[uris:resources:read uris:resources:command].freeze
  MODELS = { "fast" => "gemma3:4b", "agent" => "qwen3:8b" }.freeze

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves(*MODELS.values, "qwen3:30b-a3b")

    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "change-mcp-#{SecureRandom.hex(4)}", name: "Changing")

    Tenant.switch(@tenant) do
      @ollama = Resource::OpenaiCompatible.create!(
        key: "ollama", name: "ollama",
        details: { "base_url" => @server.base_url, "models" => MODELS },
        credentials: { "api_key" => "kept" }
      )
      @hosted = Resource::OpenaiCompatible.create!(
        key: "hosted", name: "Hosted", default_inference: true,
        details: { "base_url" => @server.base_url, "models" => { "fast" => "gemma3:4b" } }
      )
      @curl = Resource::Curl.create!(key: "curl", name: "Curl")
    end
  end

  teardown do
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end

  test "a change names one setting and keeps every other, the credential included" do
    changed = tool(@tenant, COMMAND, "resource", do: "change", key: "ollama", input: {
      name: "ollama on the Mac", settings: { "models.agent": "qwen3:30b-a3b" }
    })

    assert_equal "ollama on the Mac", changed["name"]
    assert changed["checking"], "the agent model is probed by a job, not in the call"

    Tenant.switch(@tenant) do
      held = @ollama.reload

      assert_equal @server.base_url, held.details["base_url"]
      assert_equal({ "fast" => "gemma3:4b", "agent" => "qwen3:30b-a3b" }, held.details["models"])
      assert_equal "kept", held.credentials["api_key"]
    end
  end

  test "a change to a model the backend does not serve is refused by the check at once" do
    changed = tool(@tenant, COMMAND, "resource", do: "change", key: "ollama", input: {
      settings: { "models.fast": "gemma3:27b" }
    })

    assert_equal false, changed["healthy"]
    assert_match(/does not serve gemma3:27b/, changed["error"])
  end

  test "a credential handed to change is refused, and nothing changes" do
    reply = call(@tenant, COMMAND, "tools/call", name: "resource", arguments: {
      do: "change", key: "ollama", input: { name: "renamed", settings: { api_key: "hunter2" } }
    })

    assert reply.dig("result", "isError")
    assert_match(/credentials never travel through here/, reply.dig("result", "content", 0, "text"))

    Tenant.switch(@tenant) do
      assert_equal "ollama", @ollama.reload.name
      assert_equal "kept", @ollama.credentials["api_key"]
      refute AuditEvent.where(channel: "mcp").any? { |event| event.arguments.to_json.include?("hunter2") }
    end
  end

  test "default moves inference to the resource named, and off the one that held it" do
    defaulted = tool(@tenant, COMMAND, "resource", do: "default", key: "ollama")

    assert_equal "inference", defaulted["default_for"]

    Tenant.switch(@tenant) do
      assert_predicate @ollama.reload, :default_inference?
      assert_not @hosted.reload.default_inference?
    end
  end

  test "default refuses a resource that serves neither storage nor inference, and a use it does not serve" do
    neither = call(@tenant, COMMAND, "tools/call", name: "resource", arguments: { do: "default", key: "curl" })
    storage = call(@tenant, COMMAND, "tools/call", name: "resource", arguments: {
      do: "default", key: "ollama", input: { for: "storage" }
    })

    assert_match(/serves neither storage nor inference/, neither.dig("result", "content", 0, "text"))
    assert_match(/does not serve storage/, storage.dig("result", "content", 0, "text"))
    Tenant.switch(@tenant) { assert_predicate @hosted.reload, :default_inference? }
  end

  test "change and default take the command scope" do
    %w[change default].each do |verb|
      reply = call(@tenant, %w[uris:resources:read], "tools/call", name: "resource", arguments: {
        do: verb, key: "ollama", input: { name: "renamed" }
      })

      assert reply.dig("result", "isError") || reply["error"], "#{verb} went through on a read grant"
    end

    Tenant.switch(@tenant) do
      assert_equal "ollama", @ollama.reload.name
      assert_not @ollama.default_inference?
    end
  end
end
