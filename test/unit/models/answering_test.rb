require "test_helper"
require_relative "../../support/fake_model_server"

class AnsweringTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("qwen3:8b")
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "ans-#{SecureRandom.hex(4)}", name: "Answering")

    Tenant.switch(@tenant) do
      @inference = Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "agent" => "qwen3:8b" } }
      )
      @lease = Feed.create!(type: Feed::NOTE, key: "Lease", title: "Lease", note: "Notice is 60 days.")
    end
    SearchIndex.refresh!
  end

  teardown { ENV.delete("URIS_INFERENCE_ORIGINS") }

  test "an answer given under another name is still the answer" do
    @server.answer_json(response: "Sixty days' notice, 60 in all [feed #{@lease.id}].", world: false)

    answered = Tenant.switch(@tenant) { Answering.new(question: "how much notice for the lease?", first: [ @lease ]).call }

    assert_equal "Sixty days' notice, 60 in all [feed #{@lease.id}].", answered.said
    assert_equal [ @lease.id ], answered.drew_on
  end

  test "a time of day and a citation are not numbers to check" do
    @server.answer_json(answer: "Give notice by 17:00, 60 days ahead [feed #{@lease.id}].", world: false)

    answered = Tenant.switch(@tenant) { Answering.new(question: "how much notice for the lease?", first: [ @lease ]).call }

    assert_empty answered.unsupported
    assert_equal 1, @server.prompts.size
  end
end
