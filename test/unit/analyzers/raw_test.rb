require "test_helper"
require_relative "../../support/fake_model_server"

class RawTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CORPUS = Rails.root.join("test/fixtures/corpus/image")

  test "a camera raw is an image, whatever the camera called it" do
    assert_equal "image/x-dcraw", MimeType.for_filename("DSC_0001.NEF")
    assert_equal "image/x-dcraw", MimeType.for_filename("IMG_4820.cr3")
    assert_equal "image/x-dcraw", MimeType.for_filename("holiday/P1000123.rw2")

    assert MimeType.raw?("DSC_0001.nef")
    assert_not MimeType.raw?("photo.jpg")
    assert_not MimeType.raw?("notes.txt")
  end

  test "a raw is described from the picture inside it, not the thumbnail vips finds first" do
    source = CORPUS.join("photo.nef")
    skip "no corpus on disk — see test/fixtures/corpus/README.md" unless source.exist?

    SearchIndex.reset!

    server = FakeModelServer.current
    server.reset!.serves("gemma3:4b")
    ENV["URIS_INFERENCE_ORIGINS"] = server.origin

    tenant = Tenant.create!(subdomain: "raw-#{SecureRandom.hex(4)}", name: "Raw")

    Tenant.switch(tenant) do
      storage = Resource::Database.create!(key: "disk", name: "Storage")
      storage.make_default_storage!
      storage.upload("photo.nef", source.binread)

      Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => server.base_url, "models" => { "vision" => "gemma3:4b" } }
      ).make_default_inference!

      Tenant.switch(tenant) { SyncResourceJob.perform_now(tenant.id, storage.id) }
    end

    server.answer_json({ summary: "A photograph off a Nikon.", tags: [ "photograph" ] })

    id = Tenant.switch(tenant) do
      Feed.joins(:references).find_by!(feed_references: { locator_key: "photo.nef" }).id
    end
    Tenant.switch(tenant) { AnalyzeFeedJob.perform_now(tenant.id, id) }

    Tenant.switch(tenant) do
      steps = steps_at("photo.nef")
      dimensions = steps.dig("dimensions", "result")

      assert_equal "image/x-dcraw", reference_at("photo.nef").mime
      assert_operator dimensions["width"], :>=, Raw::MINIMUM
      assert_equal "A photograph off a Nikon.",
                   steps.dig("summary", "result", "summary")
    end

    sent = Base64.strict_decode64(server.attachments.last.first.split(",", 2).last)
    path = File.join(Dir.mktmpdir, "sent.jpg")
    File.binwrite(path, sent)

    edges = %w[width height].map { |edge| Open3.capture2("vipsheader", "-f", edge, path).first.to_i }

    assert_equal Setting.definition!("hires_size").default.to_i, edges.max
  ensure
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end
end
