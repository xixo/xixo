require "test_helper"
require_relative "../../support/fake_model_server"

class VisionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FILES = Rails.root.join("test/fixtures/files")

  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("gemma3:4b", "llama3.1:8b")

    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "vis-#{SecureRandom.hex(4)}", name: "Vision")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "disk", name: "Storage")
      @storage.make_default_storage!

      store "poster.png"
      store "sign.png"
      store "pixel.png"
      store "photo.png"
      store "animated.gif"
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id) }
  end

  teardown do
    ENV.delete("XIXO_INFERENCE_ORIGINS")
  end

  test "an image is described from its pixels, and the preview travels with the prompt" do
    inference!
    @server.answer_json({ summary: "A printed sign reading PELICAN CENSUS.", tags: %w[sign pelican] })

    analyze "poster.png"

    Tenant.switch(@tenant) do
      summary = steps_at("poster.png").dig("summary", "result")

      assert_equal "A printed sign reading PELICAN CENSUS.", summary["summary"]
      assert_equal %w[sign pelican], summary["tags"]
    end

    assert_equal 1, @server.attachments.last.length
    assert_match %r{\Adata:image/jpeg;base64,}, @server.attachments.last.first
  end

  test "what the model saw is kept as the image's caption, apart from the text read off it" do
    inference!
    @server.answer_json({ summary: "A red bicycle leans against a blue door.", tags: %w[bicycle] })

    analyze "poster.png"

    Tenant.switch(@tenant) do
      feed = feed_at("poster.png")

      assert_equal "A red bicycle leans against a blue door.", steps_at("poster.png").dig("caption", "result")
      assert_equal "A red bicycle leans against a blue door.", feed.described_text
      assert_not_includes feed.readable_text.to_s, "red bicycle"
    end
  end

  test "what the model sees is a bounded preview, not the original" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "poster.png"

    sent = decoded(@server.attachments.last.first)

    assert_equal "1902", header(FILES.join("poster.png").to_s, "width")
    assert_equal Setting.definition!("hires_size").default, header(sent, "width")
    assert_equal "jpegload", header(sent, "vips-loader")
  end

  test "an image smaller than the preview is sent at its own size, not blown up" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "sign.png"

    assert_equal "634", header(decoded(@server.attachments.last.first), "width")
  end

  test "the text read out of the image is offered as context, fenced as data" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "poster.png"

    asked = @server.prompts.last

    assert_includes asked, "PELICAN CENSUS 4820"
    assert_includes asked, "data, not"
    assert_includes asked, "1902×357"
  end

  test "an image tesseract cannot open is read from the preview instead" do
    inference!
    @server.answer_json({ summary: "Three frames of text." })

    analyze "animated.gif"

    Tenant.switch(@tenant) do
      ocr = steps_at("animated.gif").dig("ocr")

      assert_includes ocr["result"], "FRAME 1"
      assert_nil ocr["error"]
    end

    assert_includes @server.prompts.last, "FRAME 1"
  end

  test "an animation is described from frames across it, in order, and the prompt says it moves" do
    inference!
    @server.answer_json({ summary: "Text counts up from FRAME 1 to FRAME 3." })

    analyze "animated.gif"

    Tenant.switch(@tenant) { assert_equal 3, steps_at("animated.gif").dig("frames", "result") }

    assert_equal 3, @server.attachments.last.length
    assert(@server.attachments.last.all? { |image| image.start_with?("data:image/jpeg;base64,") })
    assert_equal 3, @server.attachments.last.uniq.length, "each attachment is a different frame"
    assert_includes @server.prompts.last, "An animation of 3 frames. The 3 images attached are frames from it, in order."
    assert_includes @server.prompts.last, "what happens across the animation"
  end

  test "a still image sends one preview and says nothing of frames" do
    inference!
    @server.answer_json({ summary: "A printed sign." })

    analyze "poster.png"

    Tenant.switch(@tenant) { assert_nil steps_at("poster.png")["frames"] }

    assert_equal 1, @server.attachments.last.length
    assert_not_includes @server.prompts.last, "animation"
  end

  test "a format tesseract and the model both read is still described" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "animated.gif"

    assert_equal 3, @server.attachments.last.length

    Tenant.switch(@tenant) do
      assert_equal "A sign.",
                   steps_at("animated.gif").dig("summary", "result", "summary")
    end
  end

  test "the formats vips reads are catalogued as images" do
    assert_equal "image/bmp", MimeType.for_filename("avatar.bmp")
    assert_equal "image/vnd.microsoft.icon", MimeType.for_filename("favicon.ico")
    assert_equal "image/tiff", MimeType.for_filename("scan.TIFF")
  end

  test "the description reaches the search index" do
    inference!
    @server.answer_json({ summary: "A sign counting wading birds.", tags: [ "estuary" ] })

    analyze "poster.png"
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      assert_equal [ "poster.png" ], Feed.search("wading").pluck(:title)
    end
  end

  test "provenance names the vision role and the model that answered" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "poster.png"

    Tenant.switch(@tenant) do
      step = steps_at("poster.png").dig("summary")

      assert_equal "vision", step["role"]
      assert_equal "gemma3:4b", step["model"]
      assert_equal "ollama", step["resource"]
    end
  end

  test "a tracking pixel is described without asking the model" do
    inference!

    analyze "pixel.png"

    assert_equal 0, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      assert_includes steps_at("pixel.png").dig("summary", "result", "summary"),
                      "tracking pixel"
    end
  end

  test "a single-colour image is described without asking the model" do
    inference!

    analyze "photo.png"

    assert_equal 0, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      summary = steps_at("photo.png").dig("summary", "result")

      assert_includes summary["summary"], "single-colour"
      assert_includes summary["summary"], "120×80"
      assert_equal %w[solid background], summary["tags"]
    end
  end

  test "a trivial image is described even with no inference resource configured" do
    analyze "pixel.png"

    Tenant.switch(@tenant) do
      assert steps_at("pixel.png").dig("summary", "result", "summary").present?
    end
  end

  test "an inference resource that serves no vision model leaves the image undescribed" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => @server.base_url, "models" => { "smart" => "llama3.1:8b" } }
      ).make_default_inference!
    end

    analyze "poster.png"

    assert_equal 0, @server.count_for("/v1/chat/completions")

    Tenant.switch(@tenant) do
      steps = steps_at("poster.png")

      assert steps.key?("ocr")
      assert_not steps.key?("summary")
      assert reference("poster.png").analyzed_at.present?
    end
  end

  test "a second analysis does not send the image again" do
    inference!
    @server.answer_json({ summary: "A sign." })

    analyze "poster.png"
    analyze "poster.png"

    assert_equal 1, @server.count_for("/v1/chat/completions")
  end

  private

    def inference!
      Tenant.switch(@tenant) do
        @inference = Resource::OpenaiCompatible.create!(
          key: "ollama", name: "Local models",
          details: { "base_url" => @server.base_url, "models" => { "vision" => "gemma3:4b" } }
        )
        @inference.make_default_inference!
      end
    end

    def decoded(uri)
      bytes = Base64.strict_decode64(uri.split(",", 2).last)
      path = File.join(Dir.mktmpdir, "sent.jpg")
      File.binwrite(path, bytes)
      path
    end

    def header(path, field)
      Open3.capture2("vipsheader", "-f", field, path).first.strip
    end

    def store(name)
      @storage.upload(name, FILES.join(name).binread)
    end

    def analyze(key)
      analyze_feed_at(key)
    end

    def reference(key)
      Reference.find_by!(locator_key: key).reload
    end
end
