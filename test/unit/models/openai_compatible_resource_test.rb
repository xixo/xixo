require "test_helper"
require_relative "../../support/fake_model_server"

class OpenaiCompatibleResourceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  MODELS = { "fast" => "gemma3:4b", "smart" => "llama3.1:8b" }.freeze

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves(MODELS.values)

    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "inf-#{SecureRandom.hex(4)}", name: "Inference")

    Tenant.switch(@tenant) do
      @resource = Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => @server.base_url, "models" => MODELS }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_INFERENCE_ORIGINS")
  end

  test "the stored type is openai-compatible and it loads back as the class" do
    assert_equal "openai-compatible", @resource.type

    Tenant.switch(@tenant) { assert_instance_of Resource::OpenaiCompatible, Resource.find(@resource.id) }
  end

  test "it declares inference and is not storage" do
    assert @resource.inference?
    assert_not @resource.storage?
    assert_raises(ArgumentError) { @resource.storage! }
  end

  test "it cannot sync, and refuses a schedule" do
    assert_not @resource.syncable?

    Tenant.switch(@tenant) do
      assert_not @resource.update(sync_interval: 300)
      assert_includes @resource.errors[:sync_interval].join, "cannot sync"
    end
  end

  test "check passes when every declared model is served" do
    Tenant.switch(@tenant) { assert @resource.check! }
  end

  test "check names the model that was never pulled" do
    @server.serves("gemma3:4b")

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { @resource.check! } }

    assert_match(/llama3\.1:8b/, error.message)
  end

  test "a model named without a tag is the one served as latest, the way ollama reads it" do
    @server.serves("gemma3:4b", "llama3.1:latest")

    Tenant.switch(@tenant) do
      @resource.update!(details: { "base_url" => @server.base_url, "models" => { "fast" => "gemma3:4b", "smart" => "llama3.1" } })

      assert @resource.check!
    end
  end

  test "a resource declaring nothing is unusable rather than vacuously healthy" do
    Tenant.switch(@tenant) do
      bare = Resource::OpenaiCompatible.create!(
        key: "bare", details: { "base_url" => @server.base_url }
      )

      assert_match(/no models are declared/, assert_raises(Resource::Unusable) { bare.check! }.message)
    end
  end

  test "a backend that only transcribes is checked by hearing a second of silence, not by listing its models" do
    @server.serves([])

    Tenant.switch(@tenant) do
      whisper = Resource::OpenaiCompatible.create!(
        key: "whisper", details: { "base_url" => @server.base_url, "models" => { "transcription" => "whisper-1" } }
      )

      assert whisper.check!
      assert_equal [ { "model" => "whisper-1", "format" => "verbose_json", "wav" => true } ], @server.heard
      assert_equal 0, @server.count_for("/v1/models")
    end
  end

  test "a transcription backend that refuses the probe fails its check" do
    @server.refuse_transcription(404)

    Tenant.switch(@tenant) do
      whisper = Resource::OpenaiCompatible.create!(
        key: "whisper", details: { "base_url" => @server.base_url, "models" => { "transcription" => "whisper-1" } }
      )

      assert_match(/answered 404/, assert_raises(Resource::Unusable) { whisper.check! }.message)
    end
  end

  test "transcription is a declared role, so a default chat model is never handed audio" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(key: "chat", details: { "base_url" => @server.base_url,
                                                                  "models" => { "default" => "gemma3:4b" } })

      assert_nil Resource.for_declared_role(:transcription)
    end
  end

  test "an unreachable endpoint records the failure rather than raising out of check" do
    Tenant.switch(@tenant) do
      gone = Resource::OpenaiCompatible.create!(
        key: "gone", details: { "base_url" => "http://127.0.0.1:1/v1", "models" => MODELS }
      )

      ENV["XIXO_INFERENCE_ORIGINS"] = "http://127.0.0.1:1"

      assert_not gone.check
      assert gone.check_error.present?
      assert_not gone.healthy?
    end
  end

  test "a server error is retryable, and not merely unusable" do
    @server.refuse(500, body: "upstream is unwell")

    error = Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @resource.summarize("hello", role: :fast) }
    end

    assert_not_kind_of Resource::Unusable, error
  end

  test "a rate limit is retryable" do
    @server.refuse(429)

    error = Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @resource.summarize("hello", role: :fast) }
    end

    assert_not_kind_of Resource::Unusable, error
  end

  test "a bad request is unusable, so the job discards rather than retrying" do
    @server.refuse(404, body: "no such model")

    Tenant.switch(@tenant) do
      assert_raises(Resource::Unusable) { @resource.summarize("hello", role: :fast) }
    end
  end

  test "a read timeout is retryable" do
    @server.hang(2)

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("read_timeout" => 1))

      error = assert_raises(Resource::Failed) { @resource.summarize("hello", role: :fast) }

      assert_not_kind_of Resource::Unusable, error
      assert_match(/did not answer in 1s/, error.message)
    end
  end

  test "prose is retried, and gives up as unusable rather than as an empty result" do
    3.times { @server.answer("I think the document is about pelicans.") }

    Tenant.switch(@tenant) do
      assert_raises(Resource::Unusable) { @resource.summarize("hello", role: :fast) }
    end

    assert_equal 3, @server.count_for("/v1/chat/completions")
  end

  test "json inside a fence is parsed" do
    @server.answer("Here you go:\n```json\n{\"summary\": \"a pelican\"}\n```\n")

    answer = Tenant.switch(@tenant) { @resource.summarize("hello", role: :fast) }

    assert_equal "a pelican", answer["summary"]
  end

  test "prose containing braces before the answer does not defeat the parse" do
    @server.answer('Use {curly} braces like this: {"summary": "a pelican"}')

    answer = Tenant.switch(@tenant) { @resource.summarize("hello", role: :fast) }

    assert_equal "a pelican", answer["summary"]
    assert_equal 1, @server.count_for("/v1/chat/completions")
  end

  test "the first parseable object wins when several are present" do
    assert_equal({ "a" => 1 }, Resource::OpenaiCompatible.extract_json('{"a":1} and {"b":2}'))
  end

  test "a brace inside a string does not unbalance the scan" do
    assert_equal({ "summary" => "a { brace" },
                 Resource::OpenaiCompatible.extract_json('here: {"summary": "a { brace"}'))
  end

  test "a nested object is kept whole" do
    assert_equal({ "a" => { "b" => 2 } }, Resource::OpenaiCompatible.extract_json('x {"a":{"b":2}} y'))
  end

  test "re-pointing the base url is dialled, not remembered" do
    Tenant.switch(@tenant) do
      @resource.check!
      @resource.update!(details: @resource.details.merge("base_url" => "http://127.0.0.1:9/v1"))

      ENV["XIXO_INFERENCE_ORIGINS"] = "http://127.0.0.1:9"

      assert_raises(Resource::Failed) { @resource.check! }
    end
  end

  test "a reasoning preamble is stripped before parsing" do
    @server.answer("<think>weighing it up</think>{\"summary\": \"a pelican\"}")

    answer = Tenant.switch(@tenant) { @resource.summarize("hello", role: :fast) }

    assert_equal "a pelican", answer["summary"]
  end

  test "an empty answer is unusable" do
    @server.answer("")

    Tenant.switch(@tenant) do
      assert_match(/answered with nothing/,
                   assert_raises(Resource::Unusable) { @resource.summarize("x", role: :fast) }.message)
    end
  end

  test "a role picks the model declared for it, and the turn records which" do
    @server.answer_json({ summary: "ok" })

    assert_equal "llama3.1:8b", @resource.model_for(:smart)
    assert_equal "gemma3:4b", @resource.model_for(:fast)

    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::NOTE, key: "hello", title: "hello")
      analysis = Analysis.open!(feed: feed, cause: "manual")

      @resource.summarize("hello", role: :smart, analysis: analysis)

      turns = analysis.reload.turns

      assert_equal [ "llama3.1:8b" ], turns.map { |turn| turn["model"] }
      assert_equal [ "smart" ], turns.map { |turn| turn["role"] }
      assert_equal [ @resource.key ], turns.map { |turn| turn["resource"] }
    end
  end

  test "an unknown role falls back only when a default model is declared" do
    Tenant.switch(@tenant) do
      assert_not @resource.serves_role?(:vision)
      assert_raises(Resource::Unusable) { @resource.model_for(:vision) }

      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("default" => "gemma3:4b")))

      assert @resource.serves_role?(:vision)
      assert_equal "gemma3:4b", @resource.model_for(:vision)
    end
  end

  test "an api key travels as a bearer token, and is absent when unset" do
    @server.answer_json({ summary: "ok" })
    Tenant.switch(@tenant) { @resource.summarize("hello", role: :fast) }

    assert_nil @server.authorizations_for("/v1/chat/completions").last

    @server.reset!.serves(MODELS.values).answer_json({ summary: "ok" })
    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("base_url" => @server.base_url),
                        credentials: { "api_key" => "sk-secret" })
      @resource.summarize("hello", role: :fast)
    end

    assert_equal "Bearer sk-secret", @server.authorizations_for("/v1/chat/completions").last
  end

  test "credentials are encrypted at rest" do
    Tenant.switch(@tenant) { @resource.update!(credentials: { "api_key" => "sk-secret" }) }

    stored = Resource.connection.select_value(
      "SELECT credentials FROM resources WHERE id = #{@resource.id}"
    )

    assert_not_includes stored.to_s, "sk-secret"
  end

  test "an origin outside the allowlist is refused, and the message names the variable" do
    ENV["XIXO_INFERENCE_ORIGINS"] = "http://127.0.0.1:9"

    Tenant.switch(@tenant) do
      assert_match(/XIXO_INFERENCE_ORIGINS/,
                   assert_raises(Resource::Unusable) { @resource.check! }.message)
    end
  end

  test "with no allowlist at all nothing is reachable" do
    ENV.delete("XIXO_INFERENCE_ORIGINS")

    Tenant.switch(@tenant) do
      assert_match(/no inference origins are permitted/,
                   assert_raises(Resource::Unusable) { @resource.check! }.message)
    end
  end

  test "a prompt is scrubbed of invalid bytes and capped before it is sent" do
    @server.answer_json({ summary: "ok" })

    Tenant.switch(@tenant) do
      @resource.summarize("caf\xE9 #{'x' * 60_000}", role: :fast)
    end

    sent = @server.prompts.last

    assert sent.valid_encoding?
    assert_operator sent.length, :<=, Resource::OpenaiCompatible::MAX_PROMPT
  end

  test "the only command is models, and there is deliberately no complete" do
    assert_equal [ :models ], Resource::OpenaiCompatible.command_schema.keys

    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @resource.command("complete", prompt: "hello") }
    end
  end

  test "the models command reports what is declared against what is served" do
    answer = Tenant.switch(@tenant) { @resource.command("models") }

    assert_equal MODELS, answer["declared"]
    assert_equal MODELS.values.sort, answer["available"].sort
  end

  test "a base_url is required" do
    Tenant.switch(@tenant) do
      resource = Resource::OpenaiCompatible.new(key: "empty", details: {})

      assert_not resource.valid?
      assert_includes resource.errors[:details].join, "base_url"
    end
  end

  test "check! passes when the agent model calls a tool on both turns" do
    @server.serves(*MODELS.values, "qwen3:8b").answer_tool_call("search", query: "invoice")
    @server.answer_tool_call("search", query: "acme")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      assert @resource.check!
    end
  end

  test "check! passes when the agent model answers in prose after calling a tool" do
    @server.serves(*MODELS.values, "qwen3:8b").answer_tool_call("search", query: "invoice")
    @server.answer("I found one invoice, acme.pdf.")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      assert @resource.check!
    end
  end

  test "check! refuses an agent model that never calls a tool" do
    @server.serves(*MODELS.values, "glm4").answer("I don't have access to external tools.")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "glm4")))

      refused = assert_raises(Resource::Unusable) { @resource.check! }

      assert_match(/answered without a tool call/, refused.message)
    end
  end

  test "check! refuses an agent model that writes its second call as text" do
    @server.serves(*MODELS.values, "llama3.1:8b").answer_tool_call("search", query: "invoice")
    @server.answer(%({"name": "get_item", "arguments": {"id": "itm_1"}}))

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "llama3.1:8b")))

      refused = assert_raises(Resource::Unusable) { @resource.check! }

      assert_match(/cannot drive a loop/, refused.message)
    end
  end

  test "check! refuses an agent model ollama loaded with too little context to hold a transcript" do
    @server.serves(*MODELS.values, "qwen3:8b").loads("qwen3:8b", context: 4096)
    @server.answer_tool_call("search", query: "invoice")
    @server.answer("I found one invoice, acme.pdf.")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      refused = assert_raises(Resource::Unusable) { @resource.check! }

      assert_match(/loaded with a 4096-token context.*OLLAMA_CONTEXT_LENGTH/, refused.message)
    end
  end

  test "check! passes an agent model with room, and a backend that is not ollama" do
    @server.serves(*MODELS.values, "qwen3:8b").loads("qwen3:8b", context: 32_768)
    2.times { @server.answer_tool_call("search", query: "invoice") }

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      assert @resource.check!

      @server.reset!.serves(*MODELS.values, "qwen3:8b")
      2.times { @server.answer_tool_call("search", query: "invoice") }

      assert @resource.check!
    end
  end

  test "check! leaves a resource with no agent role alone" do
    @server.serves(*MODELS.values)

    Tenant.switch(@tenant) do
      assert @resource.check!
      assert_equal 0, @server.count_for("/v1/chat/completions")
    end
  end

  test "a check of a model that must be probed only lists it, and the probe waits for a job" do
    @server.serves(*MODELS.values, "qwen3:8b")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      assert_enqueued_with(job: CheckResourceJob, args: [ @resource.id ]) { assert @resource.check }
      assert_equal 0, @server.count_for("/v1/chat/completions")
      assert_predicate @resource.reload, :checking?

      2.times { @server.answer_tool_call("search", query: "invoice") }
      perform_enqueued_jobs(only: CheckResourceJob)

      assert_predicate @resource.reload, :healthy?
    end
  end

  test "a check asked for just after another keeps the last result until its probe finishes" do
    @server.serves(*MODELS.values, "qwen3:8b")

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))
      checked = 1.minute.ago.change(usec: 0)
      @resource.update_columns(checked_at: checked, check_error: nil)

      assert @resource.check
      @resource.reload

      assert_predicate @resource, :checking?
      assert_equal checked, @resource.checked_at

      2.times { @server.answer_tool_call("search", query: "invoice") }
      perform_enqueued_jobs(only: CheckResourceJob)
      @resource.reload

      assert_not @resource.checking?
      assert_operator @resource.checked_at, :>, checked
      assert_equal 2, @server.count_for("/v1/chat/completions")
    end
  end

  test "a probe whose worker never finished stops reading as checking" do
    Tenant.switch(@tenant) do
      @resource.update_columns(probing_since: (Resource::PROBE_ABANDONED_AFTER + 1.minute).ago)

      assert_not @resource.checking?
    end
  end

  test "a check refuses a model never pulled at once, with nothing left to probe" do
    @server.serves(*MODELS.values)

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("models" => MODELS.merge("agent" => "qwen3:8b")))

      assert_no_enqueued_jobs(only: CheckResourceJob) { assert_not @resource.check }
      assert_match(/does not serve qwen3:8b/, @resource.reload.check_error)
      assert_not @resource.checking?
    end
  end

  test "a check of a resource with nothing to probe is whole" do
    Tenant.switch(@tenant) do
      assert_no_enqueued_jobs(only: CheckResourceJob) { assert @resource.check }
      assert_predicate @resource.reload, :healthy?
    end
  end

  test "an agent turn streams, so a model that thinks past the read timeout is waited for while it speaks" do
    @server.answer("Four Korken jars hold a kilo of flour each.").trickle(0.4)

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("read_timeout" => 1))

      said = @resource.converse(messages: [ { role: "user", content: "How many jars?" } ], role: "fast")

      assert_equal "Four Korken jars hold a kilo of flour each.", said["content"]
    end
  end

  test "an agent turn that goes silent past the read timeout fails as retryable" do
    @server.answer("never heard").hang(2)

    Tenant.switch(@tenant) do
      @resource.update!(details: @resource.details.merge("read_timeout" => 1))

      failed = assert_raises(Resource::Failed) do
        @resource.converse(messages: [ { role: "user", content: "How many jars?" } ], role: "fast")
      end

      assert_match(/did not answer in 1s/, failed.message)
    end
  end

  test "a streamed tool call is put back together from its fragments" do
    @server.answer_tool_calls([ [ "search", { query: "korken" } ], [ "feed", { id: "65" } ] ])

    said = Tenant.switch(@tenant) do
      @resource.converse(messages: [ { role: "user", content: "Find it." } ], tools: [ Resource::OpenaiCompatible::CHAIN_TOOL ], role: "fast")
    end

    assert_equal %w[search feed], said["tool_calls"].map { |call| call.dig("function", "name") }
    assert_equal({ "query" => "korken" }, JSON.parse(said["tool_calls"][0].dig("function", "arguments")))
    assert_equal({ "id" => "65" }, JSON.parse(said["tool_calls"][1].dig("function", "arguments")))
    assert_equal "call_0_0", said["tool_calls"][0]["id"]
  end

  test "a streamed error event fails the turn rather than passing for an empty answer" do
    gathering = Resource::OpenaiCompatible::Gathering.new(streamed: true)

    failed = assert_raises(Resource::Failed) do
      gathering << %(data: {"error": {"message": "model ran out of memory"}}\n\n)
    end

    assert_equal "model ran out of memory", failed.message
  end

  test "a backend that ignores stream and answers in one piece is still read" do
    gathering = Resource::OpenaiCompatible::Gathering.new(streamed: false)
    gathering << %({"choices": [{"message": {"role": "assistant", "content": "four"}}]})

    assert_equal "four", gathering.message["content"]
  end

  test "reasoning streamed apart from the answer is kept for the record" do
    gathering = Resource::OpenaiCompatible::Gathering.new(streamed: true)
    gathering << %(data: {"choices": [{"delta": {"reasoning": "Each jar holds "}}]}\n\ndata: {"choices": [{"del)
    gathering << %(ta": {"reasoning": "one litre."}}]}\n\ndata: {"choices": [{"delta": {"content": "Four."}}]}\n\ndata: [DONE]\n\n)

    said = gathering.message

    assert_equal "Each jar holds one litre.", said["reasoning"]
    assert_equal "Four.", said["content"]
  end

  test "an answer that never ends is cut off at the limit instead of held in memory" do
    endless("application/json", %({"data": [{"id": "#{"m" * 1000}"}, )) do |origin|
      resource = against(origin)

      stub_const(Resource::OpenaiCompatible, :MAX_BYTES, 64.kilobytes) do
        failed = Timeout.timeout(15) { assert_raises(Resource::Failed) { resource.answers! } }

        assert_match(/127\.0\.0\.1 sent more than #{64.kilobytes} bytes/, failed.message)
      end
    end
  end

  test "a streamed turn that never ends is cut off at the limit too" do
    event = "data: #{JSON.generate('choices' => [ { 'delta' => { 'content' => 'x' * 1000 } } ])}\n\n"

    endless("text/event-stream", event) do |origin|
      resource = against(origin)

      stub_const(Resource::OpenaiCompatible, :MAX_BYTES, 64.kilobytes) do
        failed = Timeout.timeout(15) do
          assert_raises(Resource::Failed) do
            resource.converse(messages: [ { role: "user", content: "hello" } ], role: "fast")
          end
        end

        assert_match(/sent more than #{64.kilobytes} bytes/, failed.message)
      end
    end
  end

  test "a refusal with an endless body is cut off at the limit as well" do
    endless("text/plain", "no " * 1000, status: "500 Internal Server Error") do |origin|
      resource = against(origin)

      stub_const(Resource::OpenaiCompatible, :MAX_BYTES, 64.kilobytes) do
        failed = Timeout.timeout(15) { assert_raises(Resource::Failed) { resource.answers! } }

        assert_match(/sent more than/, failed.message)
      end
    end
  end

  private

    def against(origin)
      ENV["XIXO_INFERENCE_ORIGINS"] = origin

      Tenant.switch(@tenant) do
        Resource::OpenaiCompatible.create!(
          key: "endless-#{SecureRandom.hex(3)}", name: "Endless",
          details: { "base_url" => "#{origin}/v1", "models" => MODELS }
        )
      end
    end

    def endless(type, chunk, status: "200 OK")
      server = TCPServer.new("127.0.0.1", 0)
      sending = Thread.new do
        socket = server.accept
        nil until socket.gets.to_s.strip.empty?
        socket.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nConnection: close\r\n\r\n")
        loop { socket.write(chunk) }
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        nil
      ensure
        socket&.close
      end

      WebMock.disable!
      yield "http://127.0.0.1:#{server.addr[1]}"
    ensure
      WebMock.enable!
      sending&.kill
      server&.close
    end
end
