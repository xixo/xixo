require "test_helper"
require_relative "../support/machines"

class LinkUploadsTest < ActionDispatch::IntegrationTest
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "uploads-#{SecureRandom.hex(4)}", name: "Uploads")
    connect!(@tenant)
    @machine = machine_on(@tenant, client_id: "box-client")
    @other = machine_on(@tenant, key: "other", client_id: "other-client")
    @body = SecureRandom.random_bytes(Resource::Machine::MOST_CHUNKED + 100)
    @staged = Tenant.switch(@tenant) { Resource::Machine.find(@machine.id).upload(StringIO.new(@body)) }
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
                         "DPoP" => dpop_proof(token, url: "http://#{host}/link/uploads/#{SecureRandom.uuid}") }
    assert_response :unauthorized
  end

  test "an upload nobody fetched in time is gone" do
    travel LinkExchange::FETCHED_WITHIN + 1.minute do
      fetch(client_id: "box-client")
    end

    assert_response :not_found
  end

  private

    def host
      "#{@tenant.subdomain}.xixo.test"
    end

    def path
      "/link/uploads/#{@staged['upload']}"
    end

    def fetch(client_id:)
      token = machine_token(@tenant, client_id: client_id)
      get path, headers: { "HOST" => host, "Authorization" => "DPoP #{token}",
                           "DPoP" => dpop_proof(token, url: "http://#{host}#{path}") }
    end
end
