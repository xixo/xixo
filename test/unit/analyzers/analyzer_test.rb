require "test_helper"

class AnalyzerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "ana-#{SecureRandom.hex(4)}", name: "Analysis")
    @bucket = "ana-#{SecureRandom.hex(6)}"

    Tenant.switch(@tenant) do
      @resource = Resource::S3.create!(
        key: @bucket,
        details: {
          "endpoint" => ENV.fetch("S3_ENDPOINT", "http://127.0.0.1:9000"),
          "region" => ENV.fetch("S3_REGION", "us-east-1")
        },
        credentials: {
          "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
          "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "xixoxixo")
        }
      )
    end

    @resource.client.create_bucket(bucket: @bucket)
    upload "invoice.pdf"
    upload "photo.png"
    @resource.client.put_object(bucket: @bucket, key: "notes.txt", body: "remember the milk")
    @resource.client.put_object(bucket: @bucket, key: "rows.csv", body: "name,amount\nash,10\nbea,20\n")

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
  end

  teardown do
    @resource.client.list_objects_v2(bucket: @bucket).contents.each do |object|
      @resource.client.delete_object(bucket: @bucket, key: object.key)
    end
    @resource.client.delete_bucket(bucket: @bucket)
  rescue Aws::S3::Errors::NoSuchBucket
    nil
  end

  test "dispatch picks an analyzer by kind, first match wins" do
    Tenant.switch(@tenant) do
      assert_instance_of Analyzer::Pdf, Analyzer.for(feed_at("invoice.pdf"))
      assert_instance_of Analyzer::Image, Analyzer.for(feed_at("photo.png"))
      assert_instance_of Analyzer::Text, Analyzer.for(feed_at("notes.txt"))
      assert_instance_of Analyzer::Data, Analyzer.for(feed_at("rows.csv"))
    end
  end

  test "a pdf yields its text and page count" do
    analyze_feed_at "invoice.pdf"

    Tenant.switch(@tenant) do
      steps = steps_at("invoice.pdf")

      assert_includes steps.dig("text", "result"), "Invoice for March"
      assert_equal "1", steps.dig("info", "result", "pages")
    end
  end

  test "an image yields its dimensions" do
    analyze_feed_at "photo.png"

    Tenant.switch(@tenant) do
      dimensions = steps_at("photo.png").dig("dimensions", "result")

      assert_equal 120, dimensions["width"]
      assert_equal 80, dimensions["height"]
    end
  end

  test "a file's embedded metadata is read once its bytes are down, and plain text is left alone" do
    analyze_feed_at "photo.png"
    analyze_feed_at "invoice.pdf"
    analyze_feed_at "notes.txt"

    Tenant.switch(@tenant) do
      photo = steps_at("photo.png").dig("metadata", "result")

      assert_equal "120x80", photo["ImageSize"]
      assert_equal "Grayscale", photo["ColorType"]
      assert_not photo.key?("ExifVersion")
      assert_not photo.key?("FileName")

      assert_equal 1, steps_at("invoice.pdf").dig("metadata", "result", "PageCount")
      assert_not steps_at("notes.txt").key?("metadata")
    end
  end

  test "a csv yields its columns and row count" do
    analyze_feed_at "rows.csv"

    Tenant.switch(@tenant) do
      shape = steps_at("rows.csv").dig("shape", "result")

      assert_equal %w[name amount], shape["columns"]
      assert_equal 2, shape["rows"]
    end
  end

  test "a completed step is not recomputed" do
    analyze_feed_at "notes.txt"

    Tenant.switch(@tenant) do
      subject = feed_at("notes.txt")
      first_finished = steps_at("notes.txt").dig("text", "finished_at")

      Analyzer.for(subject, analysis: analysis_at("notes.txt")).run

      assert_equal first_finished, steps_at("notes.txt").dig("text", "finished_at")
    end
  end

  test "force recomputes a step" do
    analyze_feed_at "notes.txt"

    Tenant.switch(@tenant) do
      subject = feed_at("notes.txt")
      analyzer = Analyzer.for(subject, analysis: analysis_at("notes.txt"))
      before = steps_at("notes.txt").dig("text", "finished_at")

      analyzer.run
      analyzer.step(:text, force: true) { "different" }

      after = steps_at("notes.txt")

      assert_not_equal before, after.dig("text", "finished_at")
      assert_equal "different", after.dig("text", "result")
    end
  end

  test "a step computed before the bytes moved is computed again" do
    analyze_feed_at "notes.txt"

    before = Tenant.switch(@tenant) { steps_at("notes.txt").dig("text") }

    @resource.client.put_object(bucket: @bucket, key: "notes.txt", body: "buy more milk")
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    analyze_feed_at "notes.txt"

    Tenant.switch(@tenant) do
      after = steps_at("notes.txt").dig("text")

      assert_equal "remember the milk", before["result"]
      assert_equal "buy more milk", after["result"]
      assert_not_equal before["finished_at"], after["finished_at"]
    end
  end

  test "a step computed after the bytes moved is left alone" do
    @resource.client.put_object(bucket: @bucket, key: "notes.txt", body: "buy more milk")
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    analyze_feed_at "notes.txt"

    finished = Tenant.switch(@tenant) do
      steps_at("notes.txt").dig("text", "finished_at")
    end

    analyze_feed_at "notes.txt"

    Tenant.switch(@tenant) do
      assert_equal finished, steps_at("notes.txt").dig("text", "finished_at")
    end
  end

  test "syncing enqueues analysis again for the item whose bytes moved, and only that one" do
    %w[invoice.pdf photo.png notes.txt rows.csv].each { |key| analyze_feed_at key }

    @resource.client.put_object(bucket: @bucket, key: "notes.txt", body: "buy more milk")

    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end
  end

  test "extracted text becomes searchable" do
    analyze_feed_at "invoice.pdf"
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      assert_equal [ "invoice.pdf" ], Feed.search("totalling").pluck(:title)
    end
  end

  test "syncing enqueues analysis for each new item" do
    Tenant.switch(@tenant) { Feed.destroy_all }

    assert_enqueued_jobs 4, only: AnalyzeFeedJob do
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end
  end
end
