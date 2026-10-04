require "test_helper"

class PublicAddressTest < ActiveSupport::TestCase
  setup do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a public address passes" do
    assert PublicAddress.permitted?("https://8.8.8.8/something")
  end

  test "loopback, private and link-local addresses are refused" do
    refute PublicAddress.permitted?("http://127.0.0.1:9000/")
    refute PublicAddress.permitted?("http://10.1.2.3/")
    refute PublicAddress.permitted?("http://192.168.1.1/")
    refute PublicAddress.permitted?("http://169.254.169.254/latest/meta-data/")
  end

  test "the ranges the old guard did not name are refused too" do
    refute PublicAddress.permitted?("http://100.64.0.1/"), "carrier-grade NAT"
    refute PublicAddress.permitted?("http://0.0.0.0/"), "this host"
    refute PublicAddress.permitted?("http://[fc00::1]/"), "unique local"
    refute PublicAddress.permitted?("http://[ff02::1]/"), "multicast"
  end

  test "loopback wearing an IPv6 costume is still loopback" do
    refute PublicAddress.permitted?("http://[::ffff:127.0.0.1]/")
    refute PublicAddress.permitted?("http://[::1]/")
  end

  test "an IPv6 address that carries an IPv4 one inside it is refused, whatever it carries" do
    refute PublicAddress.permitted?("http://[::127.0.0.1]/"), "IPv4-compatible"
    refute PublicAddress.permitted?("http://[2002:7f00:1::]/"), "6to4 wrapping 127.0.0.1"
    refute PublicAddress.permitted?("http://[2001:0:4136:e378:8000:63bf:3fff:fdd2]/"), "Teredo"
    refute PublicAddress.permitted?("http://[64:ff9b:1::a00:5]/"), "local-use NAT64"
    refute PublicAddress.permitted?("http://[fec0::1]/"), "site-local"
    assert PublicAddress.permitted?("http://[2606:4700:4700::1111]/"), "an ordinary global address"
  end

  test "a scheme that is not http or https is refused" do
    error = assert_raises(PublicAddress::Blocked) { PublicAddress.permitted!("file:///etc/passwd") }

    assert_match(/not an http or https URL/, error.message)
  end

  test "a host that does not resolve is unresolvable, not blocked" do
    assert_raises(PublicAddress::Unresolvable) do
      PublicAddress.permitted!("https://#{SecureRandom.hex(12)}.invalid/")
    end
  end

  test "allowing private fetches waves the address rules through and not the scheme rules" do
    assert PublicAddress.permitted?("http://127.0.0.1:9000/", allow_private: true)

    assert_raises(PublicAddress::Blocked) do
      PublicAddress.permitted!("file:///etc/passwd", allow_private: true)
    end
  end
end
