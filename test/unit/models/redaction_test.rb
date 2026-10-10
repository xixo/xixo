require "test_helper"

class RedactionTest < ActiveSupport::TestCase
  LEAKY = "https://ash:hunter2@dav.example.test/cal?page=2&access_token=s3cret answered 500".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "red-#{SecureRandom.hex(4)}", name: "Redaction")
  end

  test "userinfo is taken out of an address" do
    assert_equal "https://dav.example.test/cal answered 500",
                 Redaction.scrub("https://ash:hunter2@dav.example.test/cal answered 500")
    assert_equal "imap://mail.example.test:993/INBOX", Redaction.scrub("imap://ash@mail.example.test:993/INBOX")
    assert_equal "https://dav.example.test/", Redaction.scrub("https://ash:p@ss@dav.example.test/")
  end

  test "credentials in a query are marked and the rest of the query is kept" do
    assert_equal "https://x.example.test/feed?page=2&access_token=[redacted]",
                 Redaction.scrub("https://x.example.test/feed?page=2&access_token=abc.def")

    %w[token key api_key sig X-Amz-Signature X-Amz-Credential password client_secret code].each do |name|
      said = Redaction.scrub("https://x.example.test/a?#{name}=hidden&q=kept")

      assert_equal "https://x.example.test/a?#{name}=[redacted]&q=kept", said
    end
  end

  test "prose, mail addresses, and plain addresses are left as they are" do
    [
      "ollama: http://127.0.0.1:11434/v1 does not serve gemma3:4b",
      "write to ash@example.test about it",
      "https://example.test/search?q=invoices&page=3"
    ].each { |said| assert_equal said, Redaction.scrub(said) }
  end

  test "nested values are scrubbed and everything else passes through" do
    assert_equal({ "message" => "https://dav.example.test/" }, Redaction.scrub({ "message" => "https://a:b@dav.example.test/" }))
    assert_equal [ "https://dav.example.test/", 4 ], Redaction.scrub([ "https://a:b@dav.example.test/", 4 ])
    assert_nil Redaction.scrub(nil)
  end

  test "the errors xixo raises never carry a credential" do
    [ Resource::Failed, Resource::Unusable, PublicFetch::Blocked, Download::Failed,
      PublicAddress::Blocked, Snapshot::Failed, Analyzer::Failed ].each do |kind|
      message = kind.new(LEAKY).message

      assert_no_match(/hunter2|s3cret/, message, kind.name)
      assert_match(/dav\.example\.test/, message, kind.name)
    end

    assert_equal "Resource::Failed", Resource::Failed.new.message
  end

  test "a fetch that fails on an address with userinfo reports the address without it" do
    stub_request(:get, "https://huge.example.test/x?token=s3cret").to_return(status: 500)

    curl = Tenant.switch(@tenant) { Resource::Curl.create!(key: "curl", name: "Curl") }
    failed = assert_raises(Resource::Failed) do
      Tenant.switch(@tenant) { curl.command("get", url: "https://ash:hunter2@huge.example.test/x?token=s3cret") }
    end

    assert_equal "curl: https://huge.example.test/x?token=[redacted] answered 500", failed.message
  end

  test "a check that fails with someone else's error is recorded without the credential" do
    Tenant.switch(@tenant) do
      resource = Resource::Curl.create!(key: "curl", name: "Curl")
      resource.define_singleton_method(:answers!) { raise URI::InvalidURIError, "bad URI: #{LEAKY}" }

      assert_not resource.check
      assert_no_match(/hunter2|s3cret/, resource.reload.check_error)
      assert_match(/URI::InvalidURIError: bad URI: https:\/\/dav\.example\.test/, resource.check_error)
    end
  end

  test "a run's error and its log lines are recorded without the credential" do
    Tenant.switch(@tenant) do
      resource = Resource::Database.create!(key: "database", name: "Storage")
      run = Run.create!(resource: resource, kind: "sync")

      run.log_fail("fetching", LEAKY)
      run.finished!(error: "RuntimeError: #{LEAKY}")
      run.reload

      assert_no_match(/hunter2|s3cret/, run.error)
      assert_no_match(/hunter2|s3cret/, run.logs)
      assert_match(/access_token=\[redacted\]/, run.logs)
    end
  end

  test "an analysis turn's error is recorded without the credential" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::NOTE, key: "note-#{SecureRandom.hex(4)}", title: "A note")
      analysis = Analysis.create!(feed: feed, cause: "manual")

      analysis.turn!(resource: "ollama", role: "fast", model: "m", number: 1, request: "hi",
                     error: { "class" => "RuntimeError", "message" => LEAKY })
      analysis.finished!(error: LEAKY)
      analysis.reload

      assert_no_match(/hunter2|s3cret/, analysis.turns.to_json)
      assert_no_match(/hunter2|s3cret/, analysis.error)
    end
  end

  test "an audit event keeps no credential in what it was told or its arguments" do
    Tenant.switch(@tenant) do
      event = AuditEvent.record(channel: "mcp", action: "fetch", status: "error",
                                told: "fetched #{LEAKY}", detail: LEAKY,
                                arguments: { "url" => LEAKY, "nested" => { "url" => LEAKY } })

      assert_no_match(/hunter2|s3cret/, [ event.told, event.detail, event.arguments.to_json ].join)
    end
  end

  test "an MCP tool error and a GraphQL refusal are scrubbed before they leave" do
    said = Tool::Base.text(LEAKY, error: true).content.first[:text]

    assert_no_match(/hunter2|s3cret/, said)

    refused = assert_raises(GraphQL::ExecutionError) { Mutations::BaseMutation.allocate.send(:refused, LEAKY) }

    assert_no_match(/hunter2|s3cret/, refused.message)
  end
end
