require "test_helper"

class S3ResourceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "s3-#{SecureRandom.hex(4)}", name: "Buckets")
  end

  teardown do
    ENV.delete("XIXO_S3_ORIGINS")
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "an endpoint inside the network is refused before a client is made for it" do
    %w[http://169.254.169.254 http://10.0.0.5:8080 http://localhost:9000 http://[::ffff:127.0.0.1]:9000].each do |endpoint|
      assert_raises(PublicFetch::Blocked, endpoint) { connection_for(endpoint) }
    end
  end

  test "an endpoint the operator names is reached even inside the network" do
    ENV["XIXO_S3_ORIGINS"] = "http://minio:9000, https://garage.internal"

    assert_instance_of Aws::S3::Client, connection_for("http://minio:9000")
    assert_instance_of Aws::S3::Client, connection_for("https://garage.internal")
    assert_raises(PublicFetch::Blocked) { connection_for("http://10.0.0.5:9000") }
  end

  test "allowing private fetches everywhere allows them here" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    assert_instance_of Aws::S3::Client, connection_for("http://10.0.0.5:9000")
  end

  test "a public endpoint gets a client that checks who actually answered" do
    assert_instance_of Resource::S3::PublicClient, connection_for("https://s3.example.test")
  end

  test "a name that resolves elsewhere by the time it is dialled is dropped before a request is sent" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepted = Thread.new { server.accept&.close }
    WebMock.disable!

    client = Resource::S3::PublicClient.new(
      endpoint: "http://127.0.0.1:#{port}", region: "us-east-1",
      access_key_id: "id", secret_access_key: "secret", force_path_style: true, retry_limit: 0
    )

    error = assert_raises(PublicFetch::Blocked) { client.head_bucket(bucket: "bucket") }

    assert_match(/127\.0\.0\.1, which is not a public address/, error.message)
  ensure
    WebMock.enable!
    accepted&.kill
    server&.close
  end

  test "get asks the bucket for a glimpse of an object and reports the size of all of it" do
    whole = "a" * (Resource::GLIMPSE_BYTES * 3)

    got = Tenant.switch(@tenant) do
      bucket = Resource::S3.create!(key: "glimpsed", details: { "endpoint" => FakeS3::ENDPOINT },
                                    credentials: { "access_key_id" => "id", "secret_access_key" => "secret" })
      bucket.client.put_object(bucket: "glimpsed", key: "big.txt", body: whole)
      asked = []
      store = bucket.client
      store.singleton_class.prepend(Module.new { define_method(:get_object) { |**options| asked << options[:range]; super(**options) } })
      bucket.command(:get, key: "big.txt").tap { assert_equal [ "bytes=0-#{Resource::GLIMPSE_BYTES - 1}" ], asked }
    end

    assert_equal whole.bytesize, got["size"].to_i
    assert_equal Resource::MAX_TEXT, got["text"].length
  end

  private

    def connection_for(endpoint)
      Tenant.switch(@tenant) do
        Resource::S3.new(
          key: "bucket", details: { "endpoint" => endpoint },
          credentials: { "access_key_id" => "id", "secret_access_key" => "secret" }
        ).send(:connection)
      end
    end
end
