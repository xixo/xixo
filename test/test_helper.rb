ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require_relative "support/offline"
require_relative "support/fake_issuer"
require_relative "support/fake_search_engine"
require_relative "support/fake_s3"
require_relative "support/mcp_client"

ENV["XIXO_PUBLIC_ORIGIN"] = nil
ENV["S3_ENDPOINT"] = FakeS3::ENDPOINT

SEARCH_ENGINE_URL = ENV["XIXO_TEST_SEARCH_ENGINE"].presence

if SEARCH_ENGINE_URL
  ENV["OPENSEARCH_URL"] = SEARCH_ENGINE_URL
else
  SearchIndex.define_singleton_method(:client) { @client ||= FakeSearchEngine.new }
end

Resource::S3.define_method(:client) { FakeS3.for(details["endpoint"]) }

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    parallelize_setup { |worker| ENV["TEST_ENV_NUMBER"] = worker.to_s }

    setup do
      Masks::Client.registry.clear!
      FakeS3.reset!
      Resource::Mcp::Sessions.clear!
      ENV["MASKS_ISSUER_TEMPLATE"] = FakeIssuer.template
    end

    teardown { Tenant.clear! }

    def requires_search_engine!
      return if SEARCH_ENGINE_URL

      skip "asserts what the search engine itself does; set XIXO_TEST_SEARCH_ENGINE to run it"
    end

    def requires_a_refusable_engine!
      return unless SEARCH_ENGINE_URL

      skip "drives a refusal only the in-process engine can be told to make"
    end

    def requires_transcription!
      model = ENV["XIXO_WHISPER_MODEL"].presence

      return if model && File.file?(model) && system("command -v #{Analyzer::Media.binary} > /dev/null")

      skip "asserts what whisper itself hears; set XIXO_WHISPER_MODEL to a ggml model file to run it"
    end

    def issuer
      FakeIssuer.current
    end

    def connect!(tenant, client_id: "items-test-client", client_secret: "items-test-secret")
      tenant.update!(
        client_id: client_id,
        client_secret: client_secret,
        registration_access_token: "items-test-registration-token",
        registration_client_uri: "#{issuer.url_for(tenant.subdomain)}/register/#{client_id}",
        connected_at: Time.current
      )
    end

    fixtures :all

    def create_feed(mime: nil, type: Feed::FILE, key: nil, title: nil, resource: nil,
                    locator_key: nil, locator: {})
      named = key || title || locator_key.to_s.split("/").last || "untitled"
      feed = Feed.create!(type: type, key: named, title: title)
      feed.references.create!(resource: resource || scratch_resource,
                              locator_key: locator_key, locator: locator,
                              mime: mime || MimeType.for_filename(locator_key))
      feed.references.reset
      feed
    end

    def scratch_resource
      @scratch_resources ||= {}
      @scratch_resources[Current.tenant.id] ||= Resource::S3.create!(
        key: "scratch-#{SecureRandom.hex(4)}",
        details: { "endpoint" => "http://127.0.0.1:1" },
        credentials: { "access_key_id" => "k", "secret_access_key" => "s" }
      )
    end

    def feed_at(locator_key)
      Feed.joins(:references).find_by!(feed_references: { locator_key: locator_key })
    end

    def assert_kept_as_synced(resource, synced, kept)
      %i[locator_for locator_key_for mime_for title_for].each do |made|
        assert_equal resource.public_send(made, synced), resource.public_send(made, kept),
                     "#{made} makes something different of a kept object than of a synced one"
      end
    end

    def json_response(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def upload(name)
      @resource.client.put_object(
        bucket: @bucket, key: name,
        body: File.binread(Rails.root.join("test/fixtures/files", name))
      )
    end

    def reference_at(key)
      Reference.find_by!(locator_key: key).reload
    end

    def analysis_at(key)
      feed_at(key).analysis
    end

    def steps_at(key)
      analysis_at(key).steps
    end

    def analyze_feed_at(key)
      held = Tenant.switch(@tenant) do
        feed = feed_at(key)
        [ feed.id, Analysis.open!(feed: feed, cause: "manual").id ]
      end

      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, held.first, held.last) }
    end
  end
end
