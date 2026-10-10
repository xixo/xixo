require "test_helper"

class JoiningTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ATTACH = <<~GQL.freeze
    mutation($key: String!, $settings: JSON) {
      attachResource(input: { type: "filesystem", key: $key, settings: $settings }) {
        resource { id key }
        checkError
      }
    }
  GQL

  SYNC = <<~GQL.freeze
    mutation($id: ID!) { syncResource(input: { id: $id }) { run { id } } }
  GQL

  SPLIT = <<~GQL.freeze
    mutation($id: ID!) { splitReference(input: { id: $id }) { feed { id title } } }
  GQL

  FILES = <<~GQL.freeze
    {
      feeds(type: "xixo:file") {
        nodes { id title references { id role locatorKey digest resource { key } } }
      }
    }
  GQL

  JOBS = [ SyncResourceJob, AnalyzeFeedJob, DigestReferencesJob ].freeze

  setup do
    @permitted = Pathname.new(Dir.mktmpdir("permitted"))
    ENV["XIXO_FILESYSTEM_ROOTS"] = @permitted.to_s

    @tenant = Tenant.create!(subdomain: "join-#{SecureRandom.hex(4)}", name: "Joining")
    @folder = (@permitted + @tenant.subdomain + "shared").tap(&:mkpath)

    write("report.txt", "the quarterly report", at: 3.days.ago)
    write("notes.txt", "notes from the meeting", at: 3.days.ago)

    connect!(@tenant)

    @left = attach("left")
    @right = attach("right")
  end

  teardown do
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
    FileUtils.remove_entry(@permitted) if @permitted&.exist?
  end

  test "two resources over one folder hold each file as one feed with two places" do
    sync(@left, @right)

    assert_equal({ "notes.txt" => %w[left right], "report.txt" => %w[left right] }, places)

    Tenant.switch(@tenant) do
      assert_equal 2, AuditEvent.where(action: "join_feeds").count
      assert_equal 1, Reference.where(locator_key: "report.txt").distinct.count(:digest)
      assert_empty Analysis.where.not(status: "done").pluck(:status, :error)
      assert_equal [ "notes from the meeting", "the quarterly report" ],
                   Feed.files.map { |feed| feed.analysis.step_result("text") }.sort
    end
  end

  test "an edited file leaves its twin until the other place reads the same bytes" do
    sync(@left, @right)

    write("report.txt", "the quarterly report, corrected", at: 1.day.from_now)
    sync(@left)

    assert_equal [ [ "left" ], [ "right" ] ], files_named("report.txt").map { |held| held.last }.sort
    assert_equal %w[left right], places["notes.txt"]

    sync(@right)

    assert_equal %w[left right], places["report.txt"]
    assert_equal 2, files.size

    Tenant.switch(@tenant) do
      assert_empty Analysis.where.not(status: "done").pluck(:status, :error)
      assert_equal "the quarterly report, corrected", feed_at("report.txt").analysis.step_result("text")
    end
  end

  test "a place kept apart stays apart when both resources sync again" do
    sync(@left, @right)

    right = Tenant.switch(@tenant) { Reference.find_by!(resource: @right, locator_key: "notes.txt") }
    split = execute(SPLIT, variables: { id: right.id })

    assert_nil split["errors"]
    assert_equal 3, files.size

    sync(@left, @right)
    perform_enqueued_jobs(only: DigestReferencesJob) { DigestReferencesJob.perform_later }

    assert_equal [ [ "left" ], [ "right" ] ], files_named("notes.txt").map { |held| held.last }.sort
    assert_equal %w[left right], places["report.txt"]

    write("notes.txt", "notes from the meeting, with actions", at: 1.day.from_now)
    sync(@left, @right)

    assert_equal %w[left right], places["notes.txt"]
  end

  private

    def attach(key)
      held = execute(ATTACH, variables: { key: key, settings: { "root" => "shared" } })

      assert_nil held["errors"]
      assert_nil held.dig("data", "attachResource", "checkError")

      Tenant.switch(@tenant) { Resource.find(held.dig("data", "attachResource", "resource", "id")) }
    end

    def sync(*resources)
      resources.each do |resource|
        run = execute(SYNC, variables: { id: resource.id }).dig("data", "syncResource", "run")

        assert_not_nil run, "#{resource.key} did not start a sync"

        drain
      end
    end

    def drain
      10.times do
        break if enqueued_jobs.none? { |job| JOBS.map(&:name).include?(job["job_class"] || job[:job].to_s) }

        perform_enqueued_jobs(only: JOBS)
      end
    end

    def files
      execute(FILES).dig("data", "feeds", "nodes").map do |node|
        originals = node["references"].select { |held| held["role"] == "original" }

        [ originals.map { |held| held["locatorKey"] }.uniq, originals.map { |held| held.dig("resource", "key") }.sort ]
      end
    end

    def files_named(name)
      files.select { |keys, _| keys == [ name ] }
    end

    def places
      files.to_h { |keys, resources| [ keys.join(","), resources ] }
    end

    def write(name, body, at:)
      (@folder + name).write(body)
      File.utime(at.to_time, at.to_time, @folder + name)
    end

    def execute(query, variables: nil)
      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test" }.merge(bearer)

      response.parsed_body
    end

    def bearer
      token = issuer.mint(subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

      { "Authorization" => "Bearer #{token}" }
    end
end
