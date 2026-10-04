require "aws-sdk-s3"

class Resource
  class S3 < Resource
    class PublicOnly < Seahorse::Client::Plugin
      option(:xixo_through, default: nil)

      class Pool < Seahorse::Client::NetHttp::ConnectionPool
        @pools = {}
        @pools_mutex = Mutex.new

        attr_accessor :through

        def self.for(options = {}, through: nil)
          held = pool_options(options)

          @pools_mutex.synchronize do
            @pools[[ held, through ]] ||= new(held).tap { |pool| pool.through = through }
          end
        end

        def start_session(endpoint)
          super.tap do |session|
            peer = IPAddr.new(session.__getobj__.instance_variable_get(:@socket).io.to_io.remote_address.ip_address)
            next if PublicAddress.admitted?(peer, through)

            session.finish
            refusal = through.nil? ? "is not a public address" : "is not an address its transport reaches"
            raise PublicFetch::Blocked, "#{URI.parse(endpoint.to_s).host} answered from #{peer}, which #{refusal}"
          end
        end
      end

      class Handler < Seahorse::Client::NetHttp::Handler
        def pool_for(config)
          Pool.for(pool_options(config), through: config.xixo_through)
        end
      end

      handler(Handler, step: :send)
    end

    class PublicClient < Aws::S3::Client
      set_api(Aws::S3::Client.api)
      add_plugin(PublicOnly)
    end

    serves :storage
    accepts "*/*"

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "Object storage",
        blurb: "One bucket over the S3 API. AWS, R2, B2, Wasabi, MinIO and Garage all answer it.",
        names: "The bucket's name",
        fields: [
          field("endpoint", "Endpoint", required: true, placeholder: "https://s3.amazonaws.com"),
          field("region", "Region", value: "us-east-1"),
          field("prefix", "Prefix", help: "Left off, the whole bucket is walked."),
          field("force_path_style", "Address the bucket by path", kind: "boolean", value: "true",
                help: "On for MinIO and Garage. Off for AWS' own endpoints."),
          field("access_key_id", "Access key", required: true, held: :credentials),
          field("secret_access_key", "Secret key", required: true, secret: true)
        ]
      }
    end

    def self.permitted_origins
      PublicAddress.origins(ENV.fetch("XIXO_S3_ORIGINS", ""))
    end

    def self.named?(target)
      permitted_origins.include?(PublicAddress.origin(target))
    end

    def self.command_schema
      {
        list: { prefix: "string?", continuation_token: "string?" },
        get: { key: "string", version_id: "string?" },
        keep: { key: "string" },
        put: { key: "string", body: "bytes" }
      }
    end

    def bucket
      key
    end

    def command_list(prefix: nil, continuation_token: nil)
      page = s3 do |client|
        client.list_objects_v2(
          bucket: bucket,
          prefix: within_prefix(prefix),
          continuation_token: continuation_token.presence,
          max_keys: 1000
        )
      end

      {
        "objects" => page.contents.map do |object|
          { "key" => object.key, "size" => object.size, "last_modified" => object.last_modified }
        end,
        "continuation_token" => page.next_continuation_token
      }
    end

    def command_get(key:, version_id: nil)
      object = s3 do |client|
        client.get_object(bucket: bucket, key: within_prefix(key), version_id: version_id.presence,
                          range: "bytes=0-#{GLIMPSE_BYTES - 1}")
      end

      size = object.content_range.to_s[%r{/(\d+)\z}, 1] || object.content_length

      glimpse(key, object.body.read, size)
    end

    def command_keep(key:) = kept(key)

    def command_put(key:, body:)
      upload(within_prefix(key), body)
    end

    def check!
      s3 { |client| client.head_bucket(bucket: bucket) }
      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      loop do
        page = s3 do |client|
          client.list_objects_v2(
            bucket: bucket,
            prefix: within_prefix(prefix),
            continuation_token: cursor.presence,
            max_keys: 1000
          )
        end

        cursor = page.next_continuation_token
        yield page.contents, cursor

        break unless page.is_truncated
      end
    end

    def object_for(name)
      within_prefix(name)

      head = s3 { |client| client.head_object(bucket: bucket, key: name.to_s) }

      Aws::S3::Types::Object.new(key: name.to_s, etag: head.etag, size: head.content_length,
                                 last_modified: head.last_modified)
    end

    def locator_for(object)
      { "bucket" => bucket, "key" => object.key, "etag" => object.etag&.delete('"') }
    end

    def locator_key_for(object)
      object.key
    end

    def download(locator)
      s3 { |client| client.get_object(bucket: locator.fetch("bucket"), key: locator.fetch("key")) }.body
    end

    def upload(key, body)
      written = s3 { |client| client.put_object(bucket: bucket, key: key, body: body) }

      { "bucket" => bucket, "key" => key, "etag" => written.etag&.delete('"') }
    end

    def client
      @client ||= connection
    end

    private


      def connection
        endpoint = reached(details.fetch("endpoint"))
        inside = via.nil? && (PublicAddress.allowed? || self.class.named?(endpoint))
        PublicAddress.permitted!(endpoint, allow_private: inside, through: through)

        options = {
          endpoint: endpoint,
          region: details.fetch("region", "us-east-1"),
          access_key_id: credentials.fetch("access_key_id"),
          secret_access_key: credentials.fetch("secret_access_key"),
          force_path_style: details.fetch("force_path_style", true)
        }

        inside ? Aws::S3::Client.new(**options) : PublicClient.new(**options, xixo_through: through)
      rescue PublicAddress::Blocked => e
        raise PublicFetch::Blocked, "#{key}: #{e.message}"
      rescue PublicAddress::Unresolvable => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end

      def s3
        yield client
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end
  end
end
