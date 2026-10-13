require "test_helper"
require_relative "../../support/fake_model_server"

class VisionBackendTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:30b-a3b", "gemma3:4b", "llava:13b", "llama3.2-vision:latest", "nomic-embed-text")
           .shows("qwen3:30b-a3b", "completion", "tools", "thinking")
           .shows("gemma3:4b", "completion", "vision")
           .shows("llava:13b", "completion", "vision")
           .shows("llama3.2-vision:latest", "completion", "tools", "vision")

    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "see-#{SecureRandom.hex(4)}", name: "Sight")
  end

  teardown do
    ENV.delete("XIXO_INFERENCE_ORIGINS")
  end

  test "a check of a backend with no vision model picks one its server says reads images" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b")

      assert backend.check!
      backend.reload

      assert_equal "gemma3:4b", backend.models["vision"]
      assert_equal "qwen3:30b-a3b", backend.models["default"]
      assert_equal "gemma3:4b", Resource.for_role(:vision).model_for(:vision)
      assert_equal "gemma3:4b reads them.", backend.sight_said
    end
  end

  test "a check leaves a vision model someone chose alone when it reads images" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b", "vision" => "llava:13b")

      assert backend.check!
      assert_equal "llava:13b", backend.reload.models["vision"]
    end
  end

  test "a check refuses a vision model that cannot read images, and names ones that can" do
    Tenant.switch(@tenant) do
      backend = attached("vision" => "qwen3:30b-a3b")

      error = assert_raises(Resource::Unusable) { backend.check! }

      assert_includes error.message, "qwen3:30b-a3b cannot read images"
      assert_includes error.message, "gemma3:4b"
    end
  end

  test "a default model that cannot read images is never handed one" do
    @server.serves("qwen3:30b-a3b").shows("qwen3:30b-a3b", "completion", "tools")

    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b")

      assert_not backend.serves_role?(:vision)
      assert_nil Resource.for_role(:vision)
      assert backend.serves_role?(:smart)
      assert_equal [ "completion", "tools" ], backend.reload.model_capabilities["qwen3:30b-a3b"]
      assert_match(/None are described\. The default model, qwen3:30b-a3b, cannot read images\./, backend.sight_said)
    end
  end

  test "a default model whose server says nothing of what it reads is never handed an image" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "mystery:7b")

      assert_not backend.serves_role?(:vision)
      assert_nil Resource.for_role(:vision)
      assert_includes backend.sight_said, "None are described. Its server does not say whether the default model, mystery:7b, reads images."
    end
  end

  test "a vision model someone named is used even when its server says nothing of what it reads" do
    Tenant.switch(@tenant) do
      backend = attached("vision" => "mystery:7b")

      assert backend.serves_role?(:vision)
      assert_equal "mystery:7b gets them. Its server does not say whether it reads images.", backend.sight_said
    end
  end

  test "LM Studio's own list says which models read images, and a check picks one" do
    @server.reset!.serves("openai/gpt-oss-20b", "mistralai/devstral-small-2-2512", "google/gemma-3-4b")
           .studio("openai/gpt-oss-20b" => "llm", "mistralai/devstral-small-2-2512" => "vlm", "google/gemma-3-4b" => "vlm")

    Tenant.switch(@tenant) do
      backend = attached("default" => "openai/gpt-oss-20b")

      assert_not backend.serves_role?(:vision)
      assert backend.check!
      backend.reload

      assert_equal({ "default" => "openai/gpt-oss-20b", "vision" => "google/gemma-3-4b" }, backend.models)
      assert_equal "google/gemma-3-4b reads them.", backend.sight_said
    end
  end

  test "a check picks no vision model outside the families known to describe images, and names what can" do
    @server.reset!.serves("openai/gpt-oss-20b", "mistralai/devstral-small-2-2512")
           .studio("openai/gpt-oss-20b" => "llm", "mistralai/devstral-small-2-2512" => "vlm")

    Tenant.switch(@tenant) do
      backend = attached("default" => "openai/gpt-oss-20b")

      assert backend.check!
      backend.reload

      assert_equal({ "default" => "openai/gpt-oss-20b" }, backend.models)
      assert_includes backend.sight_said, "Set the Vision model to one that reads images: mistralai/devstral-small-2-2512."
    end
  end

  test "the vision role goes to a backend known to read images before the default one whose server says nothing" do
    Tenant.switch(@tenant) do
      attached("default" => "mystery:7b", key: "studio")
      seeing = Resource::OpenaiCompatible.create!(key: "ollama", name: "Local models",
                                                  details: { "base_url" => @server.base_url, "models" => { "vision" => "gemma3:4b" } })
      Resource::OpenaiCompatible.create!(key: "named", name: "Named",
                                         details: { "base_url" => @server.base_url, "models" => { "vision" => "mystery:7b" } })

      assert_equal seeing, Resource.for_role(:vision)
    end
  end

  test "saving only the vision model in the form keeps the model every other role uses" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b")
      grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "admin", "scope" => Grant::SCOPES.join(" ")))

      Resource::Changing.new(backend, grant: grant).change!(settings: { "models.vision" => "gemma3:4b" })

      assert_equal({ "default" => "qwen3:30b-a3b", "vision" => "gemma3:4b" }, backend.reload.models)
    end
  end

  test "a scheduled check that picks a vision model analyzes again the images whose summary failed" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b")
      storage = Resource::Database.create!(key: "disk", name: "Storage")
      failed = Feed.create!(type: Feed::FILE, key: "dog.jpeg", title: "dog.jpeg")
      Reference.record!(feed: failed, resource: storage, locator_key: "dog.jpeg", locator: { "key" => "dog.jpeg" },
                        mime: "image/jpeg").analyzed!
      Analysis.open!(feed: failed, cause: "upload").tap do |analysis|
        analysis.write_step!("summary", { "finished_at" => Time.current.iso8601(3),
                                          "error" => { "class" => "Resource::Unusable", "message" => "answered 400" } })
        analysis.finished!(error: "The summary failed. answered 400")
      end

      assert_includes Feed.unsummarized, failed

      assert_enqueued_with(job: SummarizeUnsummarizedJob) { CheckResourceJob.perform_now(backend.id) }
      assert_equal "gemma3:4b", backend.reload.models["vision"]

      assert_difference -> { failed.analyses.count } do
        perform_enqueued_jobs(only: SummarizeUnsummarizedJob)
      end
    end
  end

  test "a backend with only an embedding model says nothing about images" do
    Tenant.switch(@tenant) do
      assert_nil attached("embedding" => "nomic-embed-text").sight_said
    end
  end

  test "a summary asks for JSON shaped by the schema it expects, which Ollama and LM Studio both take" do
    @server.answer_json({ summary: "ok", tags: [] }).answer_json({ title: "ok" })
    schema = { type: "object", properties: { summary: { type: "string" } }, required: %w[summary] }

    Tenant.switch(@tenant) do
      backend = attached("default" => "qwen3:30b-a3b")
      backend.summarize("hello", role: :fast, schema: schema)
      backend.summarize("hello", role: :fast)
    end

    assert_equal [ { "type" => "json_schema", "json_schema" => { "name" => "answer", "schema" => schema.deep_stringify_keys } },
                   { "type" => "text" } ], @server.formats
  end

  private

    def attached(given = nil, key: "ollama", **models)
      models = given || models
      Resource::OpenaiCompatible.create!(
        key: key, name: "Local models",
        details: { "base_url" => @server.base_url, "models" => models }
      ).tap(&:make_default_inference!)
    end
end
