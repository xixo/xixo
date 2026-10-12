class Resource
  class XixoAgent
    class Shell
      Ran = Data.define(:status, :out, :err)

      class Pin
        attr_reader :seen

        def initialize(pinned)
          @pinned = pinned.to_s.strip.presence
        end

        def verify(arguments)
          @seen = arguments[:key].fingerprint("sha256")

          @pinned.nil? || ActiveSupport::SecurityUtils.secure_compare(@seen, @pinned)
        end

        def refused?
          @pinned.present? && @seen.present? && @seen != @pinned
        end

        def verify_signature
          yield
        end
      end

      CONNECTED_WITHIN = 15
      RAN_WITHIN = 120
      MOST_HEARD = 1.megabyte
      SENT_IN = 32.kilobytes

      def self.open(address:, port:, user:, key:, pinned:)
        require "net/ssh"
        require "ed25519"
        require "bcrypt_pbkdf"

        pin = Pin.new(pinned)
        ssh = start(address, user, port, key, pin)

        yield new(ssh, pin.seen)
      ensure
        ssh.close if ssh && !ssh.closed?
      end

      def self.start(address, user, port, key, pin)
        Net::SSH.start(
          address, user,
          port: port, key_data: [ key ], keys: [], keys_only: true, use_agent: false,
          auth_methods: %w[publickey], non_interactive: true, config: false,
          timeout: CONNECTED_WITHIN, verify_host_key: pin, logger: Logger.new(IO::NULL)
        )
      rescue Net::SSH::AuthenticationFailed
        raise Resource::Failed, "#{address} refused the key for #{user}"
      rescue Net::SSH::Exception, SystemCallError, SocketError, Timeout::Error => e
        raise Resource::Failed, "#{address} offered the host key #{pin.seen}, not the one kept, so nothing was sent to it" if pin.refused?

        raise Resource::Failed, "#{address} could not be reached over SSH: #{e.class}"
      end

      attr_reader :host_key

      def initialize(ssh, host_key)
        @ssh = ssh
        @host_key = host_key
      end

      def run(command, stdin: nil, within: RAN_WITHIN)
        out = +""
        err = +""
        status = nil

        channel = @ssh.open_channel do |opened|
          opened.exec(command) do |held, started|
            raise Resource::Failed, "the machine would not run a command" unless started

            held.on_data { |_, data| out << data if out.bytesize < MOST_HEARD }
            held.on_extended_data { |_, _, data| err << data if err.bytesize < MOST_HEARD }
            held.on_request("exit-status") { |_, data| status = data.read_long }
            feed(held, stdin)
          end
        end

        deadline = within.seconds.from_now
        @ssh.loop(0.1) { channel.active? && Time.current < deadline }
        raise Resource::Failed, "a command ran past #{within.to_i}s" if channel.active?

        Ran.new(status: status, out: out, err: err)
      end

      private

        def feed(channel, stdin)
          if stdin.respond_to?(:read)
            while (part = stdin.read(SENT_IN))
              channel.send_data(part)
            end
          elsif stdin
            channel.send_data(stdin.to_s)
          end

          channel.eof!
        end
    end
  end
end
