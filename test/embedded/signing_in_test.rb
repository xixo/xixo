require_relative "test_helper"

class SigningInTest < EmbeddedTest
  setup { tenant.disconnect! }

  def follow!
    seen = []

    while response.redirect? && seen.size < 10
      location = response.location
      seen << location

      assert location.start_with?("/", ORIGIN), "#{location} leaves xixo's origin, after #{seen.inspect}"

      break if URI.parse(location).path == "/"

      get URI.parse(location).request_uri
    end

    seen
  end

  def approve!
    params = { approve: "yes", hid: hidden_value("hid"), shown: hidden_value("shown") }

    travel(Masks::Server::HandshakesController::WAIT + 1.second) { post "/id/handshake", params: params }
  end

  test "a fresh install signs its first person in through its own masks, on one origin" do
    get "/"

    assert_redirected_to "/auth/handshake"

    assert set_up_owner!["settled"], "the first account is set up"

    get "/auth/handshake"
    follow!

    assert_response :success
    assert hidden_value("hid"), "masks asks the owner to approve xixo"

    approve!

    assert response.location.start_with?("#{ORIGIN}/auth/handshake/callback"), response.location

    follow!

    assert tenant.reload.connected?, "the handshake stored xixo's client credentials"

    get "/auth/"
    follow!

    get "/auth/session"

    assert_response :success
    assert_equal "owner", response.parsed_body["nickname"]
  end
end
