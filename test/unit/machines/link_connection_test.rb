require "test_helper"
require_relative "../../support/machines"

module RefusalRecorder
  def self.reasons = (@reasons ||= [])

  def refuse(reason)
    RefusalRecorder.reasons << reason
    super
  end
end

ApplicationCable::Connection.prepend(RefusalRecorder)

class LinkConnectionTest < ActionCable::Connection::TestCase
  include Machines
  include ActiveJob::TestHelper

  tests ApplicationCable::Connection

  setup do
    @tenant = Tenant.create!(subdomain: "machines-#{SecureRandom.hex(4)}", name: "Machines")
    connect!(@tenant)
    @machine = machine_on(@tenant, client_id: "box-client")
  end

  test "an enrolled machine's bound token with a proof for the socket connects as its machine" do
    token = machine_token(@tenant, client_id: "box-client")

    present(token, dpop_proof(token, url: cable_url))

    assert_equal @machine, connection.machine
    assert_equal "box-client", connection.client_id
    assert_nil connection.grant
  end

  test "a token without the xixo:link scope is refused" do
    token = machine_token(@tenant, client_id: "box-client", scopes: %w[xixo:catalog:read])

    assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }
  end

  test "a person's token naming xixo link's client is refused" do
    token = machine_token(@tenant, client_id: "box-client", subject: "someone")

    assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }
  end

  test "a token bound to no key is refused, as Bearer or as DPoP" do
    token = machine_token(@tenant, client_id: "box-client", bound: false)

    assert_reject_connection { present(token, nil, scheme: "Bearer") }
    assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }
  end

  test "a bound token presented as Bearer is refused" do
    token = machine_token(@tenant, client_id: "box-client")

    assert_reject_connection { present(token, nil, scheme: "Bearer") }
  end

  test "a proof made with another key is refused" do
    token = machine_token(@tenant, client_id: "box-client")

    assert_reject_connection do
      present(token, dpop_proof(token, url: cable_url, key: OpenSSL::PKey::EC.generate("prime256v1")))
    end
  end

  test "a proof made for another URL, another method, or long ago is refused" do
    token = machine_token(@tenant, client_id: "box-client")

    assert_reject_connection { present(token, dpop_proof(token, url: "http://#{@tenant.subdomain}.xixo.test/mcp")) }
    assert_reject_connection { present(token, dpop_proof(token, url: cable_url, method: "POST")) }
    assert_reject_connection { present(token, dpop_proof(token, url: cable_url, iat: 10.minutes.ago.to_i)) }
  end

  test "a proof made for another token is refused" do
    token = machine_token(@tenant, client_id: "box-client")
    other = machine_token(@tenant, client_id: "box-client")

    assert_reject_connection { present(token, dpop_proof(other, url: cable_url)) }
  end

  test "a proof is good for one connection" do
    token = machine_token(@tenant, client_id: "box-client")
    proof = dpop_proof(token, url: cable_url)

    present(token, proof)
    assert_reject_connection { present(token, proof) }
  end

  test "a proof another process already took is refused here too" do
    token = machine_token(@tenant, client_id: "box-client")
    proof = dpop_proof(token, url: cable_url)
    header, claims = proof.split(".").first(2).map { |part| JSON.parse(Base64.urlsafe_decode64(part + ("=" * (-part.size % 4)))) }

    assert ProofMark.first?("#{Masks::Client::Proof.thumbprint(header['jwk'])}:#{claims['jti']}", expires_in: 120)

    assert_reject_connection { present(token, proof) }
  end

  test "a client no machine here was enrolled as is told so for good, and so is an archived machine" do
    RefusalRecorder.reasons.clear
    stranger = machine_token(@tenant, client_id: "stranger")
    assert_reject_connection { present(stranger, dpop_proof(stranger, url: cable_url)) }

    Tenant.switch(@tenant) { @machine.update!(archived_at: Time.current) }
    token = machine_token(@tenant, client_id: "box-client")
    assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }

    assert_equal [ "unknown_machine" ] * 2, RefusalRecorder.reasons
  end

  test "a token xixo cannot vouch for is refused without saying the machine is gone" do
    RefusalRecorder.reasons.clear
    token = machine_token(@tenant, client_id: "box-client")
    expired = machine_token(@tenant, client_id: "box-client", expires_in: -1.minute)

    assert_reject_connection { present(token, dpop_proof(token, url: cable_url, method: "POST")) }
    assert_reject_connection { present(expired, dpop_proof(expired, url: cable_url)) }

    assert_empty RefusalRecorder.reasons
  end

  test "the client xixo link beside the server named is turned away to wait while xixo binds it" do
    RefusalRecorder.reasons.clear
    root = Pathname.new(Dir.mktmpdir)
    root.join(@tenant.subdomain).tap(&:mkpath).join("client_id").write("local-client\n")
    ENV["XIXO_LOCAL_LINK"] = root.to_s
    token = machine_token(@tenant, client_id: "local-client")

    assert_enqueued_with(job: EnrollLocalLinkJob, args: [ @tenant.subdomain ]) do
      assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }
    end
    assert_empty RefusalRecorder.reasons
  ensure
    ENV.delete("XIXO_LOCAL_LINK")
    FileUtils.rm_rf(root) if root
  end

  test "another tenant's machine is refused here" do
    other = Tenant.create!(subdomain: "machines-#{SecureRandom.hex(4)}", name: "Elsewhere")
    machine_on(other, client_id: "elsewhere-client")
    token = machine_token(other, client_id: "elsewhere-client")

    assert_reject_connection { present(token, dpop_proof(token, url: cable_url)) }
  end

  private

    def cable_url
      "http://#{@tenant.subdomain}.xixo.test/cable"
    end

    def present(token, proof, scheme: "DPoP")
      connect "/cable", headers: {
        "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "#{scheme} #{token}", "DPoP" => proof
      }.compact
    end
end
