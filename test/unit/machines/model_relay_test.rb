require "test_helper"
require_relative "../../support/machines"

module RelayingMachine
  class << self
    attr_accessor :script
  end

  def ask(verb, args = {}, within: nil)
    return super(verb, args, **{ within: within }.compact) if RelayingMachine.script.nil?

    RelayingMachine.script.call(verb.to_s, args.to_h.deep_stringify_keys)
  end
end

Resource::Machine.prepend(RelayingMachine)

class ModelRelayTest < ActiveSupport::TestCase
  include Machines

  MODELS = { "data" => [ { "id" => "qwen3:8b" } ] }.to_json

  setup do
    @tenant = Tenant.create!(subdomain: "relay-#{SecureRandom.hex(4)}", name: "Relay")
    @machine = machine_on(@tenant, key: "studio")
    Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge(
        "tools" => %w[browse search read models],
        "services" => [ { "kind" => "ollama", "port" => 11434, "address" => "100.64.0.9" } ]
      )))
    end
    @asked = []
    @answers = {}
    RelayingMachine.script = lambda do |verb, args|
      @asked << [ verb, args ]
      raise "asked #{verb}" unless verb == "relay"

      @answers.fetch(args["path"]) { raise "asked #{args['path']}" }
    end
  end

  teardown do
    RelayingMachine.script = nil
  end

  test "a model server at a linked machine's address is asked through xixo link on it" do
    @answers["/v1/models"] = { "status" => 200, "content_type" => "application/json", "body" => MODELS }

    Tenant.switch(@tenant) do
      server = server_at("http://100.64.0.9:11434/v1", { "fast" => "qwen3:8b" })

      assert_equal @machine, server.relayed_by
      assert server.answers!
    end

    assert_equal [ [ "relay", { "port" => 11434, "method" => "GET", "path" => "/v1/models", "within" => 120 } ] ], @asked
  end

  test "a server added through the machine itself is asked on the machine's own loopback" do
    @answers["/v1/chat/completions"] = {
      "status" => 200, "content_type" => "text/event-stream",
      "body" => "data: #{{ choices: [ { delta: { content: '{"ok":true}' } } ] }.to_json}\n\ndata: [DONE]\n\n"
    }

    Tenant.switch(@tenant) do
      server = server_at("http://127.0.0.1:11434/v1", { "fast" => "qwen3:8b" }, via: @machine)

      assert_equal "{\"ok\":true}", server.send(:ask, "say ok", "qwen3:8b", [])
    end

    verb, args = @asked.last
    assert_equal "relay", verb
    assert_equal [ 11434, "POST", "/v1/chat/completions" ], args.values_at("port", "method", "path")
    assert_equal "qwen3:8b", JSON.parse(args["body"])["model"]
  end

  test "a server with only embedding models says what to do, in plain words" do
    @answers["/v1/models"] = { "status" => 200, "content_type" => "application/json",
                               "body" => { data: [ { id: "nomic-embed-text" } ] }.to_json }

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Unusable) { server_at("http://100.64.0.9:11434/v1", {}).answers! }

      assert_no_match(/details|—/, error.message)
      assert_match(/Download one in it/, error.message)
    end
  end

  test "the server shows its machine is offline instead of not working" do
    Tenant.switch(@tenant) do
      server = server_at("http://100.64.0.9:11434/v1", { "fast" => "qwen3:8b" })
      @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge("connected" => false)))

      assert_not server.check
      assert server.reload.offline?
      assert_nil server.check_error
    end

    assert_empty @asked
  end

  test "an error page from the model server is a failure, and an old xixo link is told to update" do
    Tenant.switch(@tenant) do
      server = server_at("http://100.64.0.9:11434/v1", { "fast" => "qwen3:8b" })

      @answers["/v1/models"] = { "status" => 503, "content_type" => "text/plain", "body" => "loading" }
      assert_raises(Resource::Failed) { server.answers! }

      RelayingMachine.script = ->(*) { raise Resource::Machine::Refusal, "studio: xixo link said xixo link does not know the verb \"relay\"" }
      error = assert_raises(Resource::Unusable) { server.answers! }
      assert_match(/update xixo link on studio/, error.message)
    end
  end

  test "a server on no linked machine still dials directly" do
    Tenant.switch(@tenant) do
      assert_nil server_at("http://10.9.9.9:11434/v1", { "fast" => "qwen3:8b" }, key: "elsewhere").relayed_by
    end
  end

  private

    def server_at(base_url, models, key: "ollama-studio", via: nil)
      Resource::OpenaiCompatible.find_by(key: key) ||
        Resource::OpenaiCompatible.create!(key: key, name: key, via: via,
                                           details: { "base_url" => base_url, "models" => models })
    end
end
