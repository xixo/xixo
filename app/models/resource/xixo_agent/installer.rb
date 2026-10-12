require "shellwords"

class Resource
  class XixoAgent
    class Installer
      BINARY = "/usr/local/bin/xixo-agent".freeze
      CONFIG_DIR = "/etc/xixo-agent".freeze
      CONFIG = "#{CONFIG_DIR}/config.json".freeze
      STATE = "/var/lib/xixo-agent".freeze
      UNIT = "/etc/systemd/system/xixo-agent.service".freeze
      UNIT_FILE = "xixo-agent.service".freeze
      SYSTEMS = { "Linux x86_64" => "amd64", "Linux aarch64" => "arm64" }.freeze
      ACCOUNT = /\A[a-z_][a-z0-9_.-]{0,31}\z/i
      CLIENT_ID = /\A[A-Za-z0-9._:-]{1,200}\z/
      FINGERPRINT = %r{\ASHA256:[A-Za-z0-9+/]{43}\z}
      FOLDERS = "@FOLDERS@".freeze
      UNSHAREABLE = /[[:cntrl:]:"'\\]/

      def initialize(agent, shell:, minter: Enrollment.method(:mint), revoker: Enrollment.method(:revoke), log: ->(*) { })
        @agent = agent
        @shell = shell
        @minter = minter
        @revoker = revoker
        @log = log
      end

      def install!
        pinned = pin!
        arch = system!
        sudo!
        user, group = account!

        place!(binary_for(arch), BINARY, mode: "0755")
        @log.call("placed the agent for linux/#{arch} at #{BINARY}")

        run!("sudo -n install -d -m 0755 #{CONFIG_DIR}")
        write!(CONFIG, JSON.pretty_generate(config), mode: "0644")
        run!("sudo -n install -d -m 0700 -o #{user} -g #{group} #{STATE}")
        @log.call("wrote #{CONFIG} sharing #{folders.size} #{'folder'.pluralize(folders.size)}")

        client_id = enroll!
        @log.call("enrolled with masks as #{client_id}")

        write!(UNIT, unit_for(user), mode: "0644")
        run!("sudo -n systemctl daemon-reload")
        run!("sudo -n systemctl enable xixo-agent")
        run!("sudo -n systemctl restart xixo-agent")
        version = run!("#{BINARY} version").strip.first(MOST_TEXT)
        @log.call("started the xixo-agent service as #{user}, version #{version}")

        @agent.enrolled!(client_id: client_id, host_key: pinned, version: version, arch: arch, revoker: @revoker)
      end

      private

        def pin!
          seen = @shell.host_key.to_s
          pinned = @agent.details.to_h["host_key"].to_s.strip

          raise Resource::Failed, "the machine offered no host key it could be held to" unless seen.match?(FINGERPRINT)

          if pinned.present? && !ActiveSupport::SecurityUtils.secure_compare(seen, pinned)
            raise Resource::Failed, "the machine offered the host key #{seen}, not #{pinned}, so nothing was sent to it"
          end

          if pinned.present?
            @log.call("the host key matched #{pinned}")
          else
            @agent.update!(details: @agent.details.to_h.merge("host_key" => seen))
            @log.call("kept the host key #{seen}")
          end

          seen
        end

        def system!
          named = run!("uname -sm").strip

          SYSTEMS.fetch(named) do
            raise Resource::Failed, "the agent installs on Linux on x86_64 or aarch64, and this machine is #{named.first(80)}"
          end
        end

        def sudo!
          ran = @shell.run("sudo -n true")
          raise Resource::Failed, "the machine ended sudo -n true without an exit status" if ran.status.nil?
          return if ran.status.zero?

          raise Resource::Failed, "#{@agent.details['user']} needs sudo without a password to install the agent"
        end

        def account!
          user = run!("id -un").strip
          group = run!("id -gn").strip

          [ user, group ].each do |name|
            raise Resource::Failed, "#{name.first(40).inspect} is not an account name the installer writes down" unless name.match?(ACCOUNT)
          end

          [ user, group ]
        end

        def enroll!
          if (earlier = @agent.client_id).present?
            @agent.unenroll!(revoker: @revoker)
            @log.call("unenrolled the earlier client #{earlier} from masks")
          end

          token = @minter.call(@agent.tenant, name: @agent.name.presence || @agent.key)
          command = [ BINARY, "enroll", "--token", "-", "--name", @agent.name.presence || @agent.key,
                      "--config", CONFIG, "--state", STATE ].shelljoin
          client_id = run!(command, stdin: token).strip

          raise Resource::Failed, "the agent enrolled but named no client" unless client_id.match?(CLIENT_ID)

          client_id
        end

        def config
          { "xixo" => @agent.tenant.origin, "issuer" => @agent.tenant.issuer, "folders" => folders }
        end

        def folders
          @folders ||= Array(@agent.details.to_h["folders"]).map(&:to_s).each do |path|
            next if path.start_with?("/") && Pathname.new(path).cleanpath.to_s == path && !path.match?(UNSHAREABLE)

            raise Resource::Failed, "#{path.first(80).inspect} is not an absolute path the agent can share"
          end
        end

        def binary_for(arch)
          held = XixoAgent.binaries + "xixo-agent-linux-#{arch}"
          return held if held.file?

          raise Resource::Failed, "this server holds no agent for linux/#{arch} under #{XixoAgent.binaries}"
        end

        def unit_for(user)
          held = XixoAgent.binaries + UNIT_FILE
          raise Resource::Failed, "this server holds no #{UNIT_FILE} under #{XixoAgent.binaries}" unless held.file?

          template = held.read
          raise Resource::Failed, "#{UNIT_FILE} names no @USER@ to run the agent as" unless template.include?("User=@USER@")
          raise Resource::Failed, "#{UNIT_FILE} names no #{FOLDERS} to share folders through" unless template.include?("\n#{FOLDERS}\n")

          template.gsub("@USER@", user).sub("#{FOLDERS}\n", bound)
        end

        def bound
          return "" if folders.empty?

          "BindReadOnlyPaths=#{folders.map { |path| %("-#{path.gsub('%', '%%')}") }.join(' ')}\n"
        end

        def place!(source, target, mode:)
          staged = "#{File.dirname(target)}/.#{File.basename(target)}.new"

          File.open(source, "rb") { |io| run!("sudo -n tee #{staged} > /dev/null", stdin: io) }

          held = run!("sudo -n sha256sum #{staged}").split.first
          unless held == Digest::SHA256.file(source).hexdigest
            run!("sudo -n rm -f #{staged}")
            raise Resource::Failed, "#{target} arrived changed on the way"
          end

          run!("sudo -n chmod #{mode} #{staged}")
          run!("sudo -n mv -f #{staged} #{target}")
        end

        def write!(target, body, mode:)
          staged = "#{target}.new"

          run!("sudo -n tee #{staged} > /dev/null", stdin: body)
          run!("sudo -n chmod #{mode} #{staged}")
          run!("sudo -n mv -f #{staged} #{target}")
        end

        def run!(command, stdin: nil)
          ran = @shell.run(command, stdin: stdin)
          return ran.out if ran.status&.zero?

          said = Redaction.scrub(ran.err.to_s.strip.lines.last.to_s.strip).to_s.first(200)
          said = "the machine ended it without an exit status" if said.blank? && ran.status.nil?
          raise Resource::Failed, "#{command.split.first(3).join(' ')} failed#{": #{said}" if said.present?}"
        end
    end
  end
end
