require "test_helper"
require_relative "../support/machines"

class AgentUploadsTest < ActionDispatch::IntegrationTest
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "uploads-#{SecureRandom.hex(4)}", name: "Uploads")
    connect!(@tenant)
    @agent = agent_on(@tenant, client_id: "box-client")
    @other = agent_on(@tenant, key: "other", client_id: "other-client")
    @body = SecureRandom.random_bytes(Resource::XixoAgent::MOST_CHUNKED + 100)
    @staged = Tenant.switch(@tenant) { Resource::XixoAgent.find(@agent.id).upload(StringIO.new(@body)) }
  end

  test "the machine an upload was staged for fetches it once with a proof for its address" do
    fetch(client_id: "box-client")

    assert_response :ok
    assert_equal @body, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]

    fetch(client_id: "box-client")
    assert_response :not_found
  end

  test "another machine cannot fetch it" do
    fetch(client_id: "other-client")

    assert_response :not_found
    fetch(client_id: "box-client")
    assert_response :ok
  end

  test "a token without a proof, or a proof for another address, is refused" do
    token = machine_token(@tenant, client_id: "box-client")

    get path, headers: { "HOST" => host, "Authorization" => "DPoP #{token}" }
    assert_response :unauthorized

    get path, headers: { "HOST" => host, "Authorization" => "DPoP #{token}",
                         "DPoP" => dpop_proof(token, url: "http://#{host}/agent/uploads/#{SecureRandom.uuid}") }
    assert_response :unauthorized
  end

  test "an upload nobody fetched in time is gone" do
    travel AgentExchange::FETCHED_WITHIN + 1.minute do
      fetch(client_id: "box-client")
    end

    assert_response :not_found
  end

  private

    def host
      "#{@tenant.subdomain}.xixo.test"
    end

    def path
      "/agent/uploads/#{@staged['upload']}"
    end

    def fetch(client_id:)
      token = machine_token(@tenant, client_id: client_id)
      get path, headers: { "HOST" => host, "Authorization" => "DPoP #{token}",
                           "DPoP" => dpop_proof(token, url: "http://#{host}#{path}") }
    end
end
