require "test_helper"

class DefaultInferenceTest < ActiveSupport::TestCase
  MODELS = { "fast" => "gemma3:4b", "smart" => "llama3.1:8b" }.freeze

  setup do
    @tenant = Tenant.create!(subdomain: "dfi-#{SecureRandom.hex(4)}", name: "Defaults")
    @other = Tenant.create!(subdomain: "dfi-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @ollama = Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => "http://127.0.0.1:1/v1", "models" => MODELS }
      )
      @studio = Resource::OpenaiCompatible.create!(
        key: "studio",
        details: { "base_url" => "http://127.0.0.1:2/v1", "models" => { "smart" => "gpt-oss-20b" } }
      )
      @disk = Resource::Database.create!(key: "disk", name: "Storage")
    end
  end

  test "there is no default inference until one is named" do
    Tenant.switch(@tenant) do
      assert_nil Resource.default_inference
      assert_raises(ArgumentError) { Resource.default_inference! }
    end
  end

  test "naming a default inference does not unseat the default storage" do
    Tenant.switch(@tenant) do
      @disk.make_default_storage!
      @ollama.make_default_inference!

      assert_equal @disk, Resource.default_storage
      assert_equal @ollama, Resource.default_inference
    end
  end

  test "a resource that is not inference cannot be the default inference" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @disk.make_default_inference! }

      @disk.default_inference = true

      assert_not @disk.valid?
      assert_includes @disk.errors[:default_inference].join, "not inference"
    end
  end

  test "the database refuses two default inference resources for one tenant" do
    Tenant.switch(@tenant) do
      @ollama.make_default_inference!

      assert_raises(ActiveRecord::RecordNotUnique) do
        Resource.transaction(requires_new: true) do
          Resource.where(id: @studio.id).update_all(default_inference: true)
        end
      end
    end
  end

  test "one tenant's default is not another tenant's" do
    Tenant.switch(@tenant) { @ollama.make_default_inference! }

    Tenant.switch(@other) { assert_nil Resource.default_inference }
  end

  test "an archived default stops being found" do
    Tenant.switch(@tenant) do
      @ollama.make_default_inference!
      @ollama.update!(archived_at: Time.current)

      assert_nil Resource.default_inference
    end
  end

  test "a role resolves to whichever resource declares it" do
    Tenant.switch(@tenant) do
      assert_equal @ollama, Resource.for_role(:fast)
      assert_includes [ @ollama, @studio ], Resource.for_role(:smart)
    end
  end

  test "the default breaks a tie between two resources serving one role" do
    Tenant.switch(@tenant) do
      @studio.make_default_inference!

      assert_equal @studio, Resource.for_role(:smart)
      assert_equal @ollama, Resource.for_role(:fast)
    end
  end

  test "a default whose last check failed gives way to one that answers" do
    Tenant.switch(@tenant) do
      @studio.make_default_inference!
      @studio.update_columns(checked_at: Time.current, check_error: "Resource::Failed: asleep")

      assert_equal @ollama, Resource.for_role(:smart)
    end
  end

  test "a default whose last check failed is still chosen when nothing else answers" do
    Tenant.switch(@tenant) do
      @studio.make_default_inference!
      [ @studio, @ollama ].each { |resource| resource.update_columns(checked_at: Time.current, check_error: "Resource::Failed: off") }

      assert_equal @studio, Resource.for_role(:smart)
    end
  end

  test "a default never checked keeps the role" do
    Tenant.switch(@tenant) do
      @studio.make_default_inference!
      @ollama.update_columns(checked_at: Time.current, check_error: nil)

      assert_equal @studio, Resource.for_role(:smart)
    end
  end

  test "the embedding model stays put when it fails, since another would forget every vector" do
    Tenant.switch(@tenant) do
      @ollama.update!(details: @ollama.details.merge("models" => MODELS.merge("embedding" => "nomic-embed-text")))
      @studio.update!(details: @studio.details.merge("models" => { "smart" => "gpt-oss-20b", "embedding" => "bge-m3" }))
      @ollama.make_default_inference!
      @ollama.update_columns(checked_at: Time.current, check_error: "Resource::Failed: asleep")

      assert_equal @ollama, Embedding.held
      assert_equal @studio, Resource.for_declared_role(:embedding)
    end
  end

  test "a role nothing declares resolves to nothing" do
    Tenant.switch(@tenant) do
      @ollama.make_default_inference!

      assert_nil Resource.for_role(:vision)
    end
  end

  test "a declared default model answers for any role" do
    Tenant.switch(@tenant) do
      @ollama.update!(details: @ollama.details.merge("models" => MODELS.merge("default" => "gemma3:4b")))

      assert_equal @ollama, Resource.for_role(:vision)
    end
  end

  test "an archived resource serves no role" do
    Tenant.switch(@tenant) do
      @ollama.update!(archived_at: Time.current)
      @studio.update!(archived_at: Time.current)

      assert_nil Resource.for_role(:smart)
    end
  end

  test "somebody's own model is never what the tenant's documents are sent to" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "mine", owner_subject: "ada",
        details: { "base_url" => "http://127.0.0.1:3/v1", "models" => { "vision" => "llava", "embedding" => "nomic" } }
      )

      assert_nil Resource.for_role(:vision)
      assert_nil Resource.for_declared_role(:embedding)
      assert_includes [ @ollama, @studio ], Resource.for_role(:smart)
    end
  end
end
