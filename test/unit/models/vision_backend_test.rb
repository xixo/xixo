require "test_helper"
require_relative "../../support/fake_model_server"

class VisionBackendTest < ActiveSupport::TestCase
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

  test "a default model whose server says nothing of what it reads still gets images" do
    Tenant.switch(@tenant) do
      backend = attached("default" => "mystery:7b")

      assert backend.serves_role?(:vision)
      assert_includes backend.sight_said, "does not say whether it reads images"
    end
  end

  test "a backend with only an embedding model says nothing about images" do
    Tenant.switch(@tenant) do
      assert_nil attached("embedding" => "nomic-embed-text").sight_said
    end
  end

  private

    def attached(models)
      Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => @server.base_url, "models" => models }
      ).tap(&:make_default_inference!)
    end
end
