require "shellwords"

class Resource
  class Machine
    class Installer
      BINARY = "/usr/local/bin/xixo-link".freeze
      CONFIG_DIR = "/etc/xixo-link".freeze
      CONFIG = "#{CONFIG_DIR}/config.json".freeze
      STATE = "/var/lib/xixo-link".freeze
      UNIT = "/etc/systemd/system/xixo-link.service".freeze
      UNIT_FILE = "xixo-link.service".freeze
      SYSTEMS = { "Linux x86_64" => "amd64", "Linux aarch64" => "arm64" }.freeze
      ACCOUNT = /\A[a-z_][a-z0-9_.-]{0,31}\z/i
      CLIENT_ID = /\A[A-Za-z0-9._:-]{1,200}\z/
      FINGERPRINT = %r{\ASHA256:[A-Za-z0-9+/]{43}\z}
      FOLDERS = "@FOLDERS@".freeze
      UNSHAREABLE = /[[:cntrl:]:"'\\]/
      PACKAGES = %w[
        ca-certificates libvips-tools libraw-bin libimage-exiftool-perl libarchive-zip-perl poppler-utils
        tesseract-ocr ffmpeg libreoffice-writer libreoffice-calc fonts-liberation
      ].freeze
      DEBIANS = %w[debian ubuntu].freeze
      APT = "sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get".freeze
      KEPT_CONFFILES = "-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold".freeze
      WRITABLE = ":rw".freeze
      MACHINE_SETTINGS = %w[lend extracts_for_others extract_unsandboxed].freeze
      INSTALLED_WITHIN = 45.minutes
      TOLD_LINES = 5

      def self.unit(user:, folders:)
        held = Machine.binaries + UNIT_FILE
        raise Resource::Failed, "this server holds no #{UNIT_FILE} under #{Machine.binaries}" unless held.file?
        raise Resource::Failed, "#{user.to_s.first(40).inspect} is not an account name the installer writes down" unless user.to_s.match?(ACCOUNT)

        template = held.read
        raise Resource::Failed, "#{UNIT_FILE} names no @USER@ to run xixo link as" unless template.include?("User=@USER@")
        raise Resource::Failed, "#{UNIT_FILE} names no #{FOLDERS} to share folders through" unless template.include?("\n#{FOLDERS}\n")

        template.gsub("@USER@", user).sub("#{FOLDERS}\n", bound(shareable!(folders)))
      end

      def self.shareable!(lines)
        Array(lines).map(&:to_s).to_h do |line|
          path = line.delete_suffix(WRITABLE)
          next [ path, line != path ] if path.start_with?("/") && Pathname.new(path).cleanpath.to_s == path && !path.match?(UNSHAREABLE)

          raise Resource::Failed, "#{line.first(80).inspect} is not an absolute path xixo link can share"
        end
      end

      def self.bound(folders)
        written, read = folders.partition { |_, writable| writable }.map { |held| held.map(&:first) }

        [ [ "BindReadOnlyPaths", read ], [ "BindPaths", written ] ].filter_map do |directive, paths|
          next if paths.empty?

          "#{directive}=#{paths.map { |path| %("-#{path.gsub('%', '%%')}") }.join(' ')}\n"
        end.join
      end

      def initialize(machine, shell:, tailnet: false, minter: Enrollment.method(:mint), revoker: Enrollment.method(:revoke),
                     log: ->(*) { })
        @machine = machine
        @shell = shell
        @tailnet = tailnet
        @minter = minter
        @revoker = revoker
        @log = log
      end

      def install!
        pinned = pin!
        arch = system!
        sudo!
        user, group = account!
        programs = programs!

        place!(binary_for(arch), BINARY, mode: "0755")
        @log.call("placed xixo link for linux/#{arch} at #{BINARY}")

        run!("sudo -n install -d -m 0755 #{CONFIG_DIR}")
        write!(CONFIG, JSON.pretty_generate(config.merge(kept_settings)), mode: "0644")
        run!("sudo -n install -d -m 0700 -o #{user} -g #{group} #{STATE}")
        run!("sudo -n chown -R #{user}:#{group} #{STATE}")
        @log.call("wrote #{CONFIG} sharing #{folders.size} #{'folder'.pluralize(folders.size)}")

        client_id = enroll!
        @machine.enrolled!(client_id: client_id, host_key: pinned, revoker: @revoker)
        @log.call("enrolled with masks as #{client_id}")

        write!(UNIT, unit_for(user), mode: "0644")
        run!("sudo -n systemctl daemon-reload")
        run!("sudo -n systemctl enable xixo-link")
        run!("sudo -n systemctl restart xixo-link")
        version = run!("#{BINARY} version").strip.first(MOST_TEXT)
        @log.call("started the xixo-link service as #{user}, version #{version}")

        @machine.enrolled!(client_id: client_id, host_key: pinned, revoker: @revoker,
                         installed: { "version" => version, "arch" => arch, "programs" => programs })
      end

      private

        def pin!
          seen = @shell.host_key.to_s
          pinned = @machine.details.to_h["host_key"].to_s.strip

          raise Resource::Failed, "the machine offered no host key it could be held to" unless seen.match?(FINGERPRINT)

          if pinned.blank? && !@tailnet
            raise Resource::Failed, "the machine is reached outside a tailnet, so its host key is needed before " \
                                    "anything is sent to it. It offered #{seen}; check that against " \
                                    "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the machine"
          end

          if pinned.present? && !ActiveSupport::SecurityUtils.secure_compare(seen, pinned)
            raise Resource::Failed, "the machine offered the host key #{seen}, not #{pinned}, so nothing was sent to it"
          end

          if pinned.present?
            @log.call("the host key matched #{pinned}")
          else
            @machine.update!(details: @machine.details.to_h.merge("host_key" => seen))
            @log.call("kept the host key #{seen}")
          end

          seen
        end

        def system!
          named = run!("uname -sm").strip

          SYSTEMS.fetch(named) do
            raise Resource::Failed, "xixo link installs on Linux on x86_64 or aarch64, and this machine is #{named.first(80)}"
          end
        end

        def sudo!
          ran = @shell.run("sudo -n true")
          raise Resource::Failed, "the machine ended sudo -n true without an exit status" if ran.status.nil?
          return if ran.status.zero?

          raise Resource::Failed, "#{@machine.details['user']} needs sudo without a password to install xixo link"
        end

        def account!
          user = run!("id -un").strip
          group = run!("id -gn").strip

          [ user, group ].each do |name|
            raise Resource::Failed, "#{name.first(40).inspect} is not an account name the installer writes down" unless name.match?(ACCOUNT)
          end

          [ user, group ]
        end

        def programs!
          unless @machine.programs?
            @log.call("left the extraction programs off, as asked")
            return "left off"
          end

          named = distribution
          unless named
            told = "skipped the extraction programs: they install with apt on Debian or Ubuntu, and this machine is " \
                   "#{released['PRETTY_NAME'].presence || released['ID'].presence || 'neither'}"
            @log.call(told)
            return told.first(200)
          end

          apt!("update -qq")
          missed = packages!
          if missed.empty?
            @log.call("installed the extraction programs with apt on #{named}")
            return "installed"
          end

          told = "installed the extraction programs with apt on #{named} except #{missed.join(', ')}, which apt " \
                 "could not install, so what needs them is not read on the machine"
          @log.call(told)
          told.first(300)
        rescue Resource::Failed => e
          told = "the extraction programs did not install, so xixo link reads only what needs no program: #{e.message}"
          @log.call(told)
          told.first(300)
        end

        def packages!
          apt!("install -y --no-install-recommends #{KEPT_CONFFILES} #{PACKAGES.join(' ')}")
          []
        rescue Resource::Failed => e
          missed = PACKAGES.reject do |package|
            apt!("install -y --no-install-recommends #{KEPT_CONFFILES} #{package}")
            true
          rescue Resource::Failed
            false
          end
          raise e if missed.size == PACKAGES.size

          missed
        end

        def distribution
          names = [ released["ID"], *released["ID_LIKE"].to_s.split ].map(&:downcase)
          (names & DEBIANS).first
        end

        def released
          @released ||= begin
            ran = @shell.run("cat /etc/os-release")
            text = ran.status&.zero? ? ran.out.to_s : ""

            text.lines.filter_map do |line|
              name, value = line.strip.split("=", 2)
              next if value.nil? || !name.match?(/\A[A-Z_]+\z/)

              [ name, value.delete_prefix('"').delete_suffix('"').first(80) ]
            end.to_h
          end
        end

        def apt!(arguments)
          ran = @shell.run("#{APT} #{arguments}", within: INSTALLED_WITHIN)
          told(ran)
          return if ran.status&.zero?

          said = Redaction.scrub([ ran.err, ran.out ].map { |held| held.to_s.strip }.find(&:present?).to_s.lines.last.to_s.strip).to_s
          said = "the machine ended it without an exit status" if said.blank? && ran.status.nil?
          raise Resource::Failed, "apt-get #{arguments.split.first} failed#{": #{said.first(200)}" if said.present?}"
        end

        def told(ran)
          [ ran.out, ran.err ].each do |held|
            held.to_s.lines.last(TOLD_LINES).each do |line|
              line = Redaction.scrub(line.strip).to_s.first(200)
              @log.call(line) if line.present?
            end
          end
        end

        def enroll!
          if (earlier = @machine.client_id).present?
            @machine.unenroll!(revoker: @revoker)
            @log.call("unenrolled the earlier client #{earlier} from masks")
          end

          token = @minter.call(@machine.tenant, name: @machine.name.presence || @machine.key)
          command = [ BINARY, "enroll", "--token", "-", "--name", @machine.name.presence || @machine.key,
                      "--config", CONFIG, "--state", STATE ].shelljoin
          client_id = run!(command, stdin: token).strip

          raise Resource::Failed, "xixo link enrolled but named no client" unless client_id.match?(CLIENT_ID)

          client_id
        end

        def config
          listed = folders.map { |path, writable| writable ? { "path" => path, "writable" => true } : path }

          { "xixo" => @machine.tenant.origin, "issuer" => @machine.tenant.issuer, "folders" => listed }
        end

        def kept_settings
          ran = @shell.run("sudo -n cat #{CONFIG}")
          held = ran.status&.zero? ? JSON.parse(ran.out.to_s) : {}
          return {} unless held.is_a?(Hash)

          kept = held.slice(*MACHINE_SETTINGS).select { |_, value| value == true }
          tools = Array(held["tools"]).select { |name| name.is_a?(String) } & Tools::NAMES
          kept["tools"] = tools if held["tools"].is_a?(Array)
          @log.call("kept #{kept.keys.to_sentence} from the config already on the machine") if kept.any?
          kept
        rescue JSON::ParserError
          {}
        end

        def folders
          @folders ||= Installer.shareable!(@machine.details.to_h["folders"])
        end

        def binary_for(arch)
          held = Machine.binaries + "xixo-link-linux-#{arch}"
          return held if held.file?

          raise Resource::Failed, "this server holds no xixo link for linux/#{arch} under #{Machine.binaries}"
        end

        def unit_for(user)
          Installer.unit(user: user, folders: @machine.details.to_h["folders"])
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
