require "test_helper"
require_relative "../../support/fake_model_server"

class SearchWideningTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!
    PassageIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("nomic-embed-text").embeds(width: SearchIndex::VECTOR_DIMENSIONS)
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "widen-#{SecureRandom.hex(4)}", name: "Widening")

    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => @server.base_url, "models" => { "embedding" => "nomic-embed-text" } }
      )
      @plan = Feed.create!(type: Feed::FILE, key: "Kilner jar storage plan.xlsx", title: "Kilner jar storage plan.xlsx")
      SearchIndex.index(@plan)
      SearchIndex.refresh!
    end

    Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))
  end

  teardown do
    Current.grant = nil
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end

  def searched(**arguments)
    Tenant.switch(@tenant) { JSON.parse(Tool::Search.call(server_context: {}, **arguments).content.first[:text]) }
  end

  test "a type that matches nothing gives way to every type that does, and says so" do
    reply = searched(query: "Kilner", type: Feed::ADDRESS)

    assert reply["widened"]
    assert_match(/Nothing of type uris:address matched.*Leave type off/, reply["note"])
    assert_includes reply["feeds"].map { |held| held["id"] }, @plan.id.to_s
  end

  test "a type that matches is kept to, and is not widened" do
    reply = searched(query: "Kilner", type: Feed::FILE)

    assert_nil reply["widened"]
    assert_equal [ @plan.id.to_s ], reply["feeds"].map { |held| held["id"] }
  end

  test "nothing anywhere is still nothing" do
    reply = searched(query: "zeppelin", type: Feed::FILE)

    assert_nil reply["widened"]
    assert_equal 0, reply["count"]
  end
end
