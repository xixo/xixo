require "test_helper"
require_relative "../../support/machines"

class InstallerTest < ActiveSupport::TestCase
  include Machines

  KEY = "SHA256:#{'A' * 43}".freeze

  class FakeShell
    Ran = Resource::Machine::Shell::Ran

    attr_reader :host_key, :ran, :written

    def initialize(host_key: KEY, answers: {})
      @host_key = host_key
      @answers = {
        /\Auname -sm\z/ => "Linux aarch64\n",
        /\Aid -un\z/ => "jon\n",
        /\Aid -gn\z/ => "jon\n",
        /\A\/usr\/local\/bin\/xixo-link enroll/ => "link-client-1\n",
        /\A\/usr\/local\/bin\/xixo-link version\z/ => "0.2.0\n",
        %r{\Acat /etc/os-release\z} => %(PRETTY_NAME="Ubuntu 24.04.3 LTS"\nID=ubuntu\nID_LIKE=debian\n)
      }.merge(answers)
      @ran = []
      @written = {}
    end

    def run(command, stdin: nil, within: nil)
      body = stdin.respond_to?(:read) ? stdin.read : stdin
      @ran << [ command, body ]
      @within = (@within || {}).merge(command => within)

      if (target = command[/\Asudo -n tee (\S+) > \/dev\/null\z/, 1])
        @written[target] = body
        return Ran.new(status: 0, out: "", err: "")
      end

      if (target = command[/\Asudo -n sha256sum (\S+)\z/, 1])
        return Ran.new(status: 0, out: "#{Digest::SHA256.hexdigest(@written[target].to_s)}  #{target}\n", err: "")
      end

      answer = @answers.find { |pattern, _| command.match?(pattern) }&.last
      return answer if answer.is_a?(Ran)

      Ran.new(status: 0, out: answer.to_s, err: "")
    end

    def commands
      @ran.map(&:first)
    end

    def within(command)
      @within.to_h[command]
    end
  end

  setup do
    @tenant = Tenant.create!(subdomain: "installs-#{SecureRandom.hex(4)}", name: "Installs")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-link-linux-arm64"), "arm binary")
    File.binwrite(File.join(@binaries, "xixo-link-linux-amd64"), "x86 binary")
    FileUtils.cp(Rails.root.join("link/xixo-link.service"), File.join(@binaries, "xixo-link.service"))
    ENV["XIXO_LINK_DIR"] = @binaries
    ENV["XIXO_PUBLIC_ORIGIN"] = "https://%{subdomain}.xixo.test"
    @minted = []
  end

  teardown do
    ENV.delete("XIXO_LINK_DIR")
    ENV["XIXO_PUBLIC_ORIGIN"] = nil
    FileUtils.rm_rf(@binaries)
  end

  test "an install places xixo link, writes its config, enrolls it, starts it, and keeps what it learned" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      box = machine
      installer(box, shell).install!
      box.reload

      assert_equal "link-client-1", box.client_id
      assert_equal KEY, box.details["host_key"]
      assert_equal({ "version" => "0.2.0", "arch" => "arm64", "programs" => "installed" }, box.details["installed"].except("at"))
    end

    assert_equal "arm binary", shell.written["/usr/local/bin/.xixo-link.new"]
    config = JSON.parse(shell.written["/etc/xixo-link/config.json.new"])
    assert_equal "https://#{@tenant.subdomain}.xixo.test", config["xixo"]
    assert_equal issuer.url_for(@tenant.subdomain), config["issuer"]
    assert_equal [ "/srv/media", "/srv/My Photos" ], config["folders"]
    assert_match(/^User=jon$/, shell.written["/etc/systemd/system/xixo-link.service.new"])

    enroll = shell.ran.find { |command, _| command.include?(" enroll ") }
    assert_equal "minted-for-Box", enroll.last
    assert_not_includes enroll.first, "minted-for-Box"
    assert_includes shell.commands, "sudo -n install -d -m 0700 -o jon -g jon /var/lib/xixo-link"
    assert_includes shell.commands, "sudo -n systemctl restart xixo-link"
  end

  test "the unit hides where people keep files and binds back only the shared folders, read-only" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      installer(machine(details: { "folders" => [ "/srv/media", "/srv/My Photos", "/home/jon/100% done" ] }), shell).install!
    end

    unit = shell.written["/etc/systemd/system/xixo-link.service.new"]
    assert_match(/^ProtectHome=tmpfs$/, unit)
    assert_match(%r{^TemporaryFileSystem=/srv:ro /mnt:ro /media:ro /opt:ro /var/lib:ro$}, unit)
    assert_includes unit, %(\nBindReadOnlyPaths="-/srv/media" "-/srv/My Photos" "-/home/jon/100%% done"\n)
    assert_no_match(/@FOLDERS@|@USER@/, unit)
  end

  test "a folder marked :rw is written to the config as writable and bound back read-write" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      installer(machine(details: { "folders" => [ "/srv/media", "/srv/inbox:rw", "/home/jon/Drop Box:rw" ] }), shell).install!
    end

    config = JSON.parse(shell.written["/etc/xixo-link/config.json.new"])
    assert_equal [ "/srv/media", { "path" => "/srv/inbox", "writable" => true },
                   { "path" => "/home/jon/Drop Box", "writable" => true } ], config["folders"]

    unit = shell.written["/etc/systemd/system/xixo-link.service.new"]
    assert_includes unit, %(\nBindReadOnlyPaths="-/srv/media"\nBindPaths="-/srv/inbox" "-/home/jon/Drop Box"\n)
    assert_no_match(/ReadWritePaths/, unit)
  end

  test "the unit caps memory, waits for the clock, keeps its work on disk, and lets its programs lower their limits" do
    unit = Rails.root.join("link/xixo-link.service").read

    assert_match(/^MemoryMax=2G$/, unit)
    assert_match(/^OOMPolicy=continue$/, unit)
    assert_match(/^After=.*\btime-sync\.target\b/, unit)
    assert_match(/^CacheDirectory=xixo-link$/, unit)
    assert_match(/^SystemCallFilter=~@privileged @resources\nSystemCallFilter=setrlimit$/, unit)
    assert_match(/^RestartPreventExitStatus=78$/, unit)
  end

  test "installing again keeps the tools and settings the machine's own config holds" do
    held = { "xixo" => "https://old.example", "folders" => [ "/old" ], "lend" => true, "extracts_for_others" => "yes",
             "tools" => [ "browse", "write", "shell" ] }
    shell = FakeShell.new(answers: { %r{\Asudo -n cat /etc/xixo-link/config.json\z} => JSON.generate(held) })

    Tenant.switch(@tenant) { installer(machine, shell).install! }

    config = JSON.parse(shell.written["/etc/xixo-link/config.json.new"])
    assert_equal [ "/srv/media", "/srv/My Photos" ], config["folders"]
    assert_equal "https://#{@tenant.subdomain}.xixo.test", config["xixo"]
    assert_equal true, config["lend"]
    assert_equal [ "browse", "write" ], config["tools"]
    assert_not config.key?("extracts_for_others")
    assert_includes shell.commands, "sudo -n chown -R jon:jon /var/lib/xixo-link"
  end

  test "a first install, with no config on the machine yet, names no tools" do
    shell = FakeShell.new(answers: { %r{\Asudo -n cat /etc/xixo-link/config.json\z} => Resource::Machine::Shell::Ran.new(status: 1, out: "", err: "No such file") })

    Tenant.switch(@tenant) { installer(machine, shell).install! }

    config = JSON.parse(shell.written["/etc/xixo-link/config.json.new"])
    assert_equal %w[folders issuer xixo], config.keys.sort
  end

  test "a machine that shares no folders binds none" do
    shell = FakeShell.new

    Tenant.switch(@tenant) { installer(machine(details: { "folders" => [] }), shell).install! }

    unit = shell.written["/etc/systemd/system/xixo-link.service.new"]
    assert_no_match(/BindReadOnlyPaths|@FOLDERS@/, unit)
    assert_match(/^ProtectHome=tmpfs$/, unit)
  end

  test "a folder that could write its own unit directives is refused before anything is written" do
    [ "/srv/media\nExecStartPre=/bin/sh -c id", "/srv/me\"dia", "/srv/media\\x0a", "/srv/a:/etc" ].each do |hostile|
      shell = FakeShell.new

      Tenant.switch(@tenant) do
        assert_raises(Resource::Failed) { installer(machine(key: "box-#{SecureRandom.hex(3)}", details: { "folders" => [ hostile ] }), shell).install! }
      end

      assert_nil shell.written["/etc/xixo-link/config.json.new"], hostile
      assert_nil shell.written["/etc/systemd/system/xixo-link.service.new"], hostile
    end
    assert_empty @minted
  end

  test "a host key other than the pinned one stops the install before anything is sent" do
    shell = FakeShell.new(host_key: "SHA256:#{'B' * 43}")

    Tenant.switch(@tenant) do
      box = machine(details: { "host_key" => KEY })

      error = assert_raises(Resource::Failed) { installer(box, shell).install! }
      assert_match(/offered the host key SHA256:B+, not #{Regexp.escape(KEY)}/, error.message)
    end

    assert_empty shell.ran
    assert_empty @minted
  end

  test "outside a tailnet, a machine with no host key kept is refused before anything is sent" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      box = machine
      error = assert_raises(Resource::Failed) { installer(box, shell, tailnet: false).install! }

      assert_match(/reached outside a tailnet, so its host key is needed.*It offered #{Regexp.escape(KEY)}/, error.message)
      assert_nil box.reload.details["host_key"]
    end

    assert_empty shell.ran
    assert_empty @minted

    Tenant.switch(@tenant) { installer(machine(key: "pinned", details: { "host_key" => KEY }), FakeShell.new, tailnet: false).install! }
  end

  test "a machine attached with an SSH key needs a host key unless a tailnet reaches it" do
    Tenant.switch(@tenant) do
      bare = Resource::Machine.new(key: "bare", details: { "host" => "93.184.216.34", "user" => "jon" },
                                     credentials: { "private_key" => "key" })
      assert_not bare.valid?
      assert_match(/Host key is needed for a machine reached outside a tailnet/, bare.errors.full_messages.to_sentence)

      wrong = Resource::Machine.new(key: "wrong", details: { "host" => "93.184.216.34", "user" => "jon", "host_key" => "ab:cd" })
      assert_not wrong.valid?
      assert_match(/must be a SHA256 fingerprint/, wrong.errors.full_messages.to_sentence)

      tailnet = Resource::Tailnet.create!(key: "tailnet")
      through = Resource::Machine.new(key: "through", via: tailnet, details: { "host" => "100.64.0.9", "user" => "jon" },
                                        credentials: { "private_key" => "key" })
      assert through.valid?, through.errors.full_messages.to_sentence

      assert through.on_tailnet?("100.64.0.9")
      assert through.on_tailnet?("fd7a:115c:a1e0::9")
      assert_not through.on_tailnet?("93.184.216.34")
      assert_not through.on_tailnet?("not an address")
      assert_not bare.on_tailnet?("100.64.0.9")
    end
  end

  test "a client enrolled by an install that fails afterward is kept, so putting the machine away unenrolls it" do
    failed = FakeShell::Ran.new(status: 1, out: "", err: "Failed to restart xixo-link.service")
    shell = FakeShell.new(answers: { /systemctl restart/ => failed })

    Tenant.switch(@tenant) do
      box = machine
      assert_raises(Resource::Failed) { installer(box, shell).install! }

      assert_equal "link-client-1", box.reload.client_id
      assert_nil box.details["installed"]

      revoked = []
      assert box.put_away(revoker: ->(_tenant, client_id) { revoked << client_id })
      assert_equal [ "link-client-1" ], revoked
    end
  end

  test "the first host key seen is kept even when the install fails after it" do
    shell = FakeShell.new(answers: { /\Auname -sm\z/ => "Darwin arm64\n" })

    Tenant.switch(@tenant) do
      box = machine
      assert_raises(Resource::Failed) { installer(box, shell).install! }

      assert_equal KEY, box.reload.details["host_key"]
    end
  end

  test "a machine that is not Linux on x86_64 or aarch64 is refused" do
    [ "Darwin arm64", "Linux armv7l", "FreeBSD amd64" ].each do |system|
      shell = FakeShell.new(answers: { /\Auname -sm\z/ => "#{system}\n" })

      Tenant.switch(@tenant) do
        error = assert_raises(Resource::Failed) { installer(machine(key: "m-#{SecureRandom.hex(2)}"), shell).install! }
        assert_match(/installs on Linux on x86_64 or aarch64, and this machine is #{system}/, error.message)
      end

      assert_equal [ "uname -sm" ], shell.commands
    end
  end

  test "a user without passwordless sudo is refused" do
    shell = FakeShell.new(answers: { /\Asudo -n true\z/ => FakeShell::Ran.new(status: 1, out: "", err: "a password is required") })

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { installer(machine, shell).install! }
      assert_match(/needs sudo without a password/, error.message)
    end
    assert_empty @minted
  end

  test "an account name the shell could misread is refused" do
    shell = FakeShell.new(answers: { /\Aid -un\z/ => "jon; rm -rf /\n" })

    Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { installer(machine, shell).install! }
    end
    assert_not(shell.commands.any? { |command| command.include?("rm -rf") })
  end

  test "a binary that arrives changed is not put in place" do
    shell = FakeShell.new(answers: { %r{\Asudo -n sha256sum /usr/local/bin} => "0000  x\n" })
    shell.define_singleton_method(:run) do |command, stdin: nil, within: nil|
      return FakeShell::Ran.new(status: 0, out: "0000  x\n", err: "") if command.start_with?("sudo -n sha256sum /usr/local/bin")

      super(command, stdin: stdin, within: within)
    end

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { installer(machine, shell).install! }
      assert_match(/arrived changed/, error.message)
    end
    assert_not_includes shell.commands, "sudo -n mv -f /usr/local/bin/.xixo-link.new /usr/local/bin/xixo-link"
  end

  test "the install job drops the private key whether the install worked or not" do
    Tenant.switch(@tenant) do
      box = Resource::Machine.create!(key: "box", name: "Box", details: { "host" => "93.184.216.34", "user" => "jon", "host_key" => KEY },
                                          credentials: { "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
      run = Run.where(resource_id: box.id, kind: "install").sole

      swapping(Resource::Machine::Shell, :open, ->(**) { raise Resource::Failed, "93.184.216.34 refused the key for jon" }) do
        InstallLinkJob.perform_now(box.id, run.id)
      end

      assert_nil box.reload.credentials["private_key"]
      assert_equal "failed", run.reload.status
      assert_match(/refused the key/, box.check_error)

      box.update!(credentials: { "private_key" => "another" })
      second = Run.where(resource_id: box.id, kind: "install").order(:id).last
      shell = FakeShell.new
      minted = @minted
      swapping(Resource::Machine::Enrollment, :mint, ->(_tenant, name:) { minted << name && "minted" }) do
        swapping(Resource::Machine::Shell, :open, ->(**, &block) { block.call(shell) }) do
          InstallLinkJob.perform_now(box.id, second.id)
        end
      end

      assert_nil box.reload.credentials["private_key"]
      assert_equal "done", second.reload.status
      assert_equal "link-client-1", box.client_id
    end
  end

  test "installing again unenrolls the earlier client before a new one is enrolled" do
    Tenant.switch(@tenant) do
      box = machine(details: { "client_id" => "link-client-0" })
      order = []
      shell = FakeShell.new

      Resource::Machine::Installer.new(
        box, shell: shell, tailnet: true,
        minter: ->(_tenant, name:) { order << [ :mint, name ] && "minted" },
        revoker: ->(_tenant, client_id) { order << [ :revoke, client_id ] }
      ).install!

      assert_equal [ [ :revoke, "link-client-0" ], [ :mint, "Box" ] ], order
      assert_equal "link-client-1", box.reload.client_id
      assert_equal "link-client-0", box.details.dig("unenrolled", "client_id")
    end
  end

  test "an install stops before enrolling again when the earlier client cannot be unenrolled" do
    Tenant.switch(@tenant) do
      box = machine(details: { "client_id" => "link-client-0" })

      assert_raises(Resource::Failed) do
        Resource::Machine::Installer.new(
          box, shell: FakeShell.new, tailnet: true,
          minter: ->(*, **) { flunk "minted while the earlier client still signs in" },
          revoker: ->(*) { raise Resource::Failed, "masks could not be reached to unenroll the machine" }
        ).install!
      end

      assert_equal "link-client-0", box.reload.client_id
    end
  end

  test "a machine put away before its install runs loses its key and its run closes" do
    Tenant.switch(@tenant) do
      box = Resource::Machine.create!(key: "box", name: "Box", details: { "host" => "93.184.216.34", "user" => "jon", "host_key" => KEY },
                                          credentials: { "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
      run = Run.where(resource_id: box.id, kind: "install").sole
      box.update_columns(archived_at: Time.current)

      swapping(Resource::Machine::Shell, :open, ->(**) { flunk "connected to a machine that was put away" }) do
        InstallLinkJob.perform_now(box.id, run.id)
      end

      assert_nil box.reload.credentials["private_key"]
      assert_equal "failed", run.reload.status
      assert_match(/put away/, run.error)
    end
  end

  test "putting a machine away drops a key still waiting to be used" do
    Tenant.switch(@tenant) do
      box = Resource::Machine.create!(key: "box", name: "Box", details: { "host" => "100.64.0.9", "user" => "jon", "host_key" => KEY },
                                          credentials: { "private_key" => "held" })

      assert box.reload.put_away(revoker: ->(*) { flunk "asked masks about a machine that never enrolled" })
      assert_nil box.reload.credentials["private_key"]
      assert box.archived_at
    end
  end

  test "a machine put away while it installs has its new client unenrolled at once" do
    Tenant.switch(@tenant) do
      box = machine
      revoked = []
      shell = FakeShell.new
      shell.define_singleton_method(:run) do |command, stdin: nil, within: nil|
        Resource::Machine.where(id: box.id).update_all(archived_at: Time.current) if command.include?("systemctl restart")
        super(command, stdin: stdin, within: within)
      end

      error = assert_raises(Resource::Failed) do
        Resource::Machine::Installer.new(box, shell: shell, tailnet: true, minter: ->(*, **) { "minted" },
                                           revoker: ->(_tenant, client_id) { revoked << client_id }).install!
      end

      assert_match(/put away while xixo link installed/, error.message)
      assert_equal [ "link-client-1" ], revoked
      assert_nil box.reload.client_id
    end
  end

  test "putting away a machine unenrolls the client it holds now, not the one it was loaded with" do
    Tenant.switch(@tenant) do
      box = machine(details: { "client_id" => "link-client-2" })
      stale = Resource::Machine.find(box.id)
      Resource::Machine.where(id: box.id).update_all([ "details = details || ?::jsonb", { "client_id" => "link-client-3" }.to_json ])
      revoked = []

      assert stale.put_away(revoker: ->(_tenant, client_id) { revoked << client_id })
      assert_equal [ "link-client-3" ], revoked
      assert_nil stale.reload.client_id
      assert_equal "link-client-3", stale.details.dig("unenrolled", "client_id")
    end
  end

  test "a machine a folder still reaches through is not unenrolled when it cannot be put away" do
    Tenant.switch(@tenant) do
      box = machine(details: { "client_id" => "link-client-0", "machine" => { "folders" => [ "/srv/media" ] } })
      Resource::Filesystem.create!(key: "media", name: "Media", via: box, details: { "folder" => "/srv/media" })

      assert_not box.reload.put_away(revoker: ->(*) { flunk "unenrolled a machine that stays attached" })
      assert_nil box.reload.archived_at
      assert_equal "link-client-0", box.client_id
    end
  end

  test "a machine that ends a command without an exit status fails the install with a reason" do
    shell = FakeShell.new(answers: { /\Asudo -n true\z/ => FakeShell::Ran.new(status: nil, out: "", err: "") })

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { installer(machine, shell).install! }
      assert_match(/without an exit status/, error.message)
    end
  end

  test "masks is asked to unenroll a machine as this tenant's client" do
    assert Resource::Machine::Enrollment.revoke(@tenant, "link-client-9")

    assert_equal [ { "subdomain" => @tenant.subdomain, "client_id" => "items-test-client", "machine" => "link-client-9" } ],
                 issuer.unenrollments.select { |held| held["subdomain"] == @tenant.subdomain }
  end

  test "a host xixo is not allowed to reach is refused before any connection" do
    Tenant.switch(@tenant) do
      box = Resource::Machine.create!(key: "box", details: { "host" => "10.0.0.5", "user" => "jon", "host_key" => KEY },
                                          credentials: { "private_key" => "key" })
      run = Run.where(resource_id: box.id, kind: "install").sole

      swapping(Resource::Machine::Shell, :open, ->(**) { flunk "connected to a private address" }) do
        InstallLinkJob.perform_now(box.id, run.id)
      end

      assert_match(/is not a public address/, run.reload.error)
    end
  end

  test "an enrollment token is asked of masks as this tenant's client, for the xixo:link scope alone" do
    token = Resource::Machine::Enrollment.mint(@tenant, name: "Box")

    assert_match(/\Aenroll-/, token)
    asked = issuer.enrollments.last
    assert_equal({ "scope" => "xixo:link", "client_name" => "Box", "expires_in" => "600",
                   "subdomain" => @tenant.subdomain, "client_id" => "items-test-client" }, asked)
  end

  test "a tenant not connected to masks enrolls nothing" do
    @tenant.disconnect!

    assert_raises(Resource::Failed) { Resource::Machine::Enrollment.mint(@tenant, name: "Box") }
  end

  test "an install puts the extraction programs on a Debian or Ubuntu machine with apt, the packages xixo link's own image uses" do
    shell = FakeShell.new

    Tenant.switch(@tenant) { installer(machine, shell).install! }

    install = shell.commands.find { |command| command.include?("apt-get install") }
    assert_equal "sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y " \
                 "--no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold " \
                 "#{Resource::Machine::Installer::PACKAGES.join(' ')}", install
    assert_equal Resource::Machine::Installer::INSTALLED_WITHIN, shell.within(install)
    assert_operator shell.commands.index { |command| command.include?("apt-get update") }, :<, shell.commands.index(install)
    assert_operator shell.commands.index(install), :<, shell.commands.index("sudo -n systemctl restart xixo-link")
  end

  test "the programs installed are the ones xixo link's own image installs" do
    image = Rails.root.join("Dockerfile.link").read
    listed = image[/apt-get install --no-install-recommends -y\s*\\?\n(.*?)&&/m, 1].to_s.split(/[\s\\]+/).reject(&:empty?)

    assert_equal listed.sort, Resource::Machine::Installer::PACKAGES.sort
  end

  test "a machine that is not Debian or Ubuntu gets xixo link without the programs, and says why" do
    told = []
    shell = FakeShell.new(answers: { %r{\Acat /etc/os-release\z} => %(PRETTY_NAME="Fedora Linux 41"\nID=fedora\n) })

    Tenant.switch(@tenant) do
      box = machine
      installer(box, shell, log: ->(line) { told << line }).install!
      box.reload

      assert_equal "link-client-1", box.client_id
      assert_match(/apt on Debian or Ubuntu, and this machine is Fedora Linux 41/, box.details.dig("installed", "programs"))
    end

    assert_no_match(/apt-get/, shell.commands.join("\n"))
    assert told.any? { |line| line.include?("Fedora Linux 41") }
  end

  test "programs that fail to install leave xixo link installed, and the failure is kept and scrubbed into the log" do
    told = []
    failed = Resource::Machine::Shell::Ran.new(status: 100, out: "", err: "Err:1 http://mirror:hunter2@apt.example/ubuntu noble\nE: Unable to locate package ffmpeg\n")
    shell = FakeShell.new(answers: { /apt-get install/ => failed })

    Tenant.switch(@tenant) do
      box = machine
      installer(box, shell, log: ->(line) { told << line }).install!
      box.reload

      assert_equal "link-client-1", box.client_id
      assert_match(/did not install, so xixo link reads only what needs no program/, box.details.dig("installed", "programs"))
    end

    assert_includes shell.commands, "sudo -n systemctl restart xixo-link"
    assert told.any? { |line| line.include?("Unable to locate package ffmpeg") }
    assert told.any? { |line| line.include?("http://apt.example/ubuntu") }
    assert_no_match(/hunter2/, told.join("\n"))
  end

  test "a package apt cannot find leaves the rest installed, and the install says which one" do
    told = []
    failed = Resource::Machine::Shell::Ran.new(status: 100, out: "", err: "E: Unable to locate package ffmpeg\n")
    shell = FakeShell.new(answers: { /apt-get install .* ffmpeg/ => failed })

    Tenant.switch(@tenant) do
      box = machine
      installer(box, shell, log: ->(line) { told << line }).install!

      assert_match(/except ffmpeg, which apt could not install/, box.reload.details.dig("installed", "programs"))
    end

    assert shell.commands.any? { |command| command.end_with?("--force-confold poppler-utils") }
  end

  test "a machine set to leave the programs off gets no apt at all" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      box = machine(details: { "programs" => false })
      installer(box, shell).install!

      assert_equal "left off", box.reload.details.dig("installed", "programs")
    end

    assert_no_match(/apt-get|os-release/, shell.commands.join("\n"))
  end

  private

    def swapping(holder, name, replacement)
      original = holder.method(name)
      holder.define_singleton_method(name) { |*args, **options, &block| replacement.call(*args, **options, &block) }
      yield
    ensure
      holder.define_singleton_method(name, original)
    end

    def machine(key: "box", details: {})
      Resource::Machine.create!(
        key: key, name: "Box",
        details: { "host" => "100.64.0.9", "user" => "jon", "folders" => [ "/srv/media", "/srv/My Photos" ] }.merge(details)
      )
    end

    def installer(box, shell, log: ->(*) { }, tailnet: true)
      minted = @minted
      Resource::Machine::Installer.new(box, shell: shell, log: log, tailnet: tailnet,
                                                minter: ->(_tenant, name:) { minted << name && "minted-for-#{name}" })
    end
end
