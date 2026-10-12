require "test_helper"
require_relative "../../support/machines"

class InstallerTest < ActiveSupport::TestCase
  include Machines

  KEY = "SHA256:#{'A' * 43}".freeze

  class FakeShell
    Ran = Resource::XixoAgent::Shell::Ran

    attr_reader :host_key, :ran, :written

    def initialize(host_key: KEY, answers: {})
      @host_key = host_key
      @answers = {
        /\Auname -sm\z/ => "Linux aarch64\n",
        /\Aid -un\z/ => "jon\n",
        /\Aid -gn\z/ => "jon\n",
        /\A\/usr\/local\/bin\/xixo-agent enroll/ => "agent-client-1\n",
        /\A\/usr\/local\/bin\/xixo-agent version\z/ => "0.2.0\n"
      }.merge(answers)
      @ran = []
      @written = {}
    end

    def run(command, stdin: nil)
      body = stdin.respond_to?(:read) ? stdin.read : stdin
      @ran << [ command, body ]

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
  end

  setup do
    @tenant = Tenant.create!(subdomain: "installs-#{SecureRandom.hex(4)}", name: "Installs")
    connect!(@tenant)
    @binaries = Dir.mktmpdir
    File.binwrite(File.join(@binaries, "xixo-agent-linux-arm64"), "arm binary")
    File.binwrite(File.join(@binaries, "xixo-agent-linux-amd64"), "x86 binary")
    FileUtils.cp(Rails.root.join("agent/xixo-agent.service"), File.join(@binaries, "xixo-agent.service"))
    ENV["XIXO_AGENT_DIR"] = @binaries
    ENV["XIXO_PUBLIC_ORIGIN"] = "https://%{subdomain}.xixo.test"
    @minted = []
  end

  teardown do
    ENV.delete("XIXO_AGENT_DIR")
    ENV["XIXO_PUBLIC_ORIGIN"] = nil
    FileUtils.rm_rf(@binaries)
  end

  test "an install places the agent, writes its config, enrolls it, starts it, and keeps what it learned" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      agent = machine
      installer(agent, shell).install!
      agent.reload

      assert_equal "agent-client-1", agent.client_id
      assert_equal KEY, agent.details["host_key"]
      assert_equal({ "version" => "0.2.0", "arch" => "arm64" }, agent.details["installed"].except("at"))
    end

    assert_equal "arm binary", shell.written["/usr/local/bin/.xixo-agent.new"]
    config = JSON.parse(shell.written["/etc/xixo-agent/config.json.new"])
    assert_equal "https://#{@tenant.subdomain}.xixo.test", config["xixo"]
    assert_equal issuer.url_for(@tenant.subdomain), config["issuer"]
    assert_equal [ "/srv/media", "/srv/My Photos" ], config["folders"]
    assert_match(/^User=jon$/, shell.written["/etc/systemd/system/xixo-agent.service.new"])

    enroll = shell.ran.find { |command, _| command.include?(" enroll ") }
    assert_equal "minted-for-Box", enroll.last
    assert_not_includes enroll.first, "minted-for-Box"
    assert_includes shell.commands, "sudo -n install -d -m 0700 -o jon -g jon /var/lib/xixo-agent"
    assert_includes shell.commands, "sudo -n systemctl restart xixo-agent"
  end

  test "the unit hides where people keep files and binds back only the shared folders, read-only" do
    shell = FakeShell.new

    Tenant.switch(@tenant) do
      installer(machine(details: { "folders" => [ "/srv/media", "/srv/My Photos", "/home/jon/100% done" ] }), shell).install!
    end

    unit = shell.written["/etc/systemd/system/xixo-agent.service.new"]
    assert_match(/^ProtectHome=tmpfs$/, unit)
    assert_match(%r{^TemporaryFileSystem=/srv:ro /mnt:ro /media:ro /opt:ro /var/lib:ro$}, unit)
    assert_includes unit, %(\nBindReadOnlyPaths="-/srv/media" "-/srv/My Photos" "-/home/jon/100%% done"\n)
    assert_no_match(/@FOLDERS@|@USER@/, unit)
  end

  test "a machine that shares no folders binds none" do
    shell = FakeShell.new

    Tenant.switch(@tenant) { installer(machine(details: { "folders" => [] }), shell).install! }

    unit = shell.written["/etc/systemd/system/xixo-agent.service.new"]
    assert_no_match(/BindReadOnlyPaths|@FOLDERS@/, unit)
    assert_match(/^ProtectHome=tmpfs$/, unit)
  end

  test "a folder that could write its own unit directives is refused before anything is written" do
    [ "/srv/media\nExecStartPre=/bin/sh -c id", "/srv/me\"dia", "/srv/media\\x0a", "/srv/a:/etc" ].each do |hostile|
      shell = FakeShell.new

      Tenant.switch(@tenant) do
        assert_raises(Resource::Failed) { installer(machine(key: "box-#{SecureRandom.hex(3)}", details: { "folders" => [ hostile ] }), shell).install! }
      end

      assert_nil shell.written["/etc/xixo-agent/config.json.new"], hostile
      assert_nil shell.written["/etc/systemd/system/xixo-agent.service.new"], hostile
    end
    assert_empty @minted
  end

  test "a host key other than the pinned one stops the install before anything is sent" do
    shell = FakeShell.new(host_key: "SHA256:#{'B' * 43}")

    Tenant.switch(@tenant) do
      agent = machine(details: { "host_key" => KEY })

      error = assert_raises(Resource::Failed) { installer(agent, shell).install! }
      assert_match(/offered the host key SHA256:B+, not #{Regexp.escape(KEY)}/, error.message)
    end

    assert_empty shell.ran
    assert_empty @minted
  end

  test "the first host key seen is kept even when the install fails after it" do
    shell = FakeShell.new(answers: { /\Auname -sm\z/ => "Darwin arm64\n" })

    Tenant.switch(@tenant) do
      agent = machine
      assert_raises(Resource::Failed) { installer(agent, shell).install! }

      assert_equal KEY, agent.reload.details["host_key"]
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
    shell.define_singleton_method(:run) do |command, stdin: nil|
      return FakeShell::Ran.new(status: 0, out: "0000  x\n", err: "") if command.start_with?("sudo -n sha256sum /usr/local/bin")

      super(command, stdin: stdin)
    end

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { installer(machine, shell).install! }
      assert_match(/arrived changed/, error.message)
    end
    assert_not_includes shell.commands, "sudo -n mv -f /usr/local/bin/.xixo-agent.new /usr/local/bin/xixo-agent"
  end

  test "the install job drops the private key whether the install worked or not" do
    Tenant.switch(@tenant) do
      agent = Resource::XixoAgent.create!(key: "box", name: "Box", details: { "host" => "93.184.216.34", "user" => "jon" },
                                          credentials: { "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
      run = Run.where(resource_id: agent.id, kind: "install").sole

      swapping(Resource::XixoAgent::Shell, :open, ->(**) { raise Resource::Failed, "93.184.216.34 refused the key for jon" }) do
        InstallAgentJob.perform_now(agent.id, run.id)
      end

      assert_nil agent.reload.credentials["private_key"]
      assert_equal "failed", run.reload.status
      assert_match(/refused the key/, agent.check_error)

      agent.update!(credentials: { "private_key" => "another" })
      second = Run.where(resource_id: agent.id, kind: "install").order(:id).last
      shell = FakeShell.new
      minted = @minted
      swapping(Resource::XixoAgent::Enrollment, :mint, ->(_tenant, name:) { minted << name && "minted" }) do
        swapping(Resource::XixoAgent::Shell, :open, ->(**, &block) { block.call(shell) }) do
          InstallAgentJob.perform_now(agent.id, second.id)
        end
      end

      assert_nil agent.reload.credentials["private_key"]
      assert_equal "done", second.reload.status
      assert_equal "agent-client-1", agent.client_id
    end
  end

  test "installing again unenrolls the earlier client before a new one is enrolled" do
    Tenant.switch(@tenant) do
      agent = machine(details: { "client_id" => "agent-client-0" })
      order = []
      shell = FakeShell.new

      Resource::XixoAgent::Installer.new(
        agent, shell: shell,
        minter: ->(_tenant, name:) { order << [ :mint, name ] && "minted" },
        revoker: ->(_tenant, client_id) { order << [ :revoke, client_id ] }
      ).install!

      assert_equal [ [ :revoke, "agent-client-0" ], [ :mint, "Box" ] ], order
      assert_equal "agent-client-1", agent.reload.client_id
      assert_equal "agent-client-0", agent.details.dig("unenrolled", "client_id")
    end
  end

  test "an install stops before enrolling again when the earlier client cannot be unenrolled" do
    Tenant.switch(@tenant) do
      agent = machine(details: { "client_id" => "agent-client-0" })

      assert_raises(Resource::Failed) do
        Resource::XixoAgent::Installer.new(
          agent, shell: FakeShell.new,
          minter: ->(*, **) { flunk "minted while the earlier client still signs in" },
          revoker: ->(*) { raise Resource::Failed, "masks could not be reached to unenroll the machine" }
        ).install!
      end

      assert_equal "agent-client-0", agent.reload.client_id
    end
  end

  test "a machine put away before its install runs loses its key and its run closes" do
    Tenant.switch(@tenant) do
      agent = Resource::XixoAgent.create!(key: "box", name: "Box", details: { "host" => "93.184.216.34", "user" => "jon" },
                                          credentials: { "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
      run = Run.where(resource_id: agent.id, kind: "install").sole
      agent.update_columns(archived_at: Time.current)

      swapping(Resource::XixoAgent::Shell, :open, ->(**) { flunk "connected to a machine that was put away" }) do
        InstallAgentJob.perform_now(agent.id, run.id)
      end

      assert_nil agent.reload.credentials["private_key"]
      assert_equal "failed", run.reload.status
      assert_match(/put away/, run.error)
    end
  end

  test "putting a machine away drops a key still waiting to be used" do
    Tenant.switch(@tenant) do
      agent = Resource::XixoAgent.create!(key: "box", name: "Box", details: { "host" => "100.64.0.9", "user" => "jon" },
                                          credentials: { "private_key" => "held" })

      assert agent.reload.put_away(revoker: ->(*) { flunk "asked masks about a machine that never enrolled" })
      assert_nil agent.reload.credentials["private_key"]
      assert agent.archived_at
    end
  end

  test "a machine put away while it installs has its new client unenrolled at once" do
    Tenant.switch(@tenant) do
      agent = machine
      revoked = []
      shell = FakeShell.new
      shell.define_singleton_method(:run) do |command, stdin: nil|
        Resource::XixoAgent.where(id: agent.id).update_all(archived_at: Time.current) if command.include?("systemctl restart")
        super(command, stdin: stdin)
      end

      error = assert_raises(Resource::Failed) do
        Resource::XixoAgent::Installer.new(agent, shell: shell, minter: ->(*, **) { "minted" },
                                           revoker: ->(_tenant, client_id) { revoked << client_id }).install!
      end

      assert_match(/put away while the agent installed/, error.message)
      assert_equal [ "agent-client-1" ], revoked
      assert_nil agent.reload.client_id
    end
  end

  test "putting away a machine unenrolls the client it holds now, not the one it was loaded with" do
    Tenant.switch(@tenant) do
      agent = machine(details: { "client_id" => "agent-client-2" })
      stale = Resource::XixoAgent.find(agent.id)
      Resource::XixoAgent.where(id: agent.id).update_all([ "details = details || ?::jsonb", { "client_id" => "agent-client-3" }.to_json ])
      revoked = []

      assert stale.put_away(revoker: ->(_tenant, client_id) { revoked << client_id })
      assert_equal [ "agent-client-3" ], revoked
      assert_nil stale.reload.client_id
      assert_equal "agent-client-3", stale.details.dig("unenrolled", "client_id")
    end
  end

  test "a machine a folder still reaches through is not unenrolled when it cannot be put away" do
    Tenant.switch(@tenant) do
      agent = machine(details: { "client_id" => "agent-client-0", "machine" => { "folders" => [ "/srv/media" ] } })
      Resource::AgentFolder.create!(key: "media", name: "Media", via: agent, details: { "folder" => "/srv/media" })

      assert_not agent.reload.put_away(revoker: ->(*) { flunk "unenrolled a machine that stays attached" })
      assert_nil agent.reload.archived_at
      assert_equal "agent-client-0", agent.client_id
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
    assert Resource::XixoAgent::Enrollment.revoke(@tenant, "agent-client-9")

    assert_equal [ { "subdomain" => @tenant.subdomain, "client_id" => "items-test-client", "machine" => "agent-client-9" } ],
                 issuer.unenrollments.select { |held| held["subdomain"] == @tenant.subdomain }
  end

  test "a host xixo is not allowed to reach is refused before any connection" do
    Tenant.switch(@tenant) do
      agent = Resource::XixoAgent.create!(key: "box", details: { "host" => "10.0.0.5", "user" => "jon" },
                                          credentials: { "private_key" => "key" })
      run = Run.where(resource_id: agent.id, kind: "install").sole

      swapping(Resource::XixoAgent::Shell, :open, ->(**) { flunk "connected to a private address" }) do
        InstallAgentJob.perform_now(agent.id, run.id)
      end

      assert_match(/is not a public address/, run.reload.error)
    end
  end

  test "an enrollment token is asked of masks as this tenant's client, for the agent scope alone" do
    token = Resource::XixoAgent::Enrollment.mint(@tenant, name: "Box")

    assert_match(/\Aenroll-/, token)
    asked = issuer.enrollments.last
    assert_equal({ "scope" => "xixo:agent", "client_name" => "Box", "expires_in" => "600",
                   "subdomain" => @tenant.subdomain, "client_id" => "items-test-client" }, asked)
  end

  test "a tenant not connected to masks enrolls nothing" do
    @tenant.disconnect!

    assert_raises(Resource::Failed) { Resource::XixoAgent::Enrollment.mint(@tenant, name: "Box") }
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
      Resource::XixoAgent.create!(
        key: key, name: "Box",
        details: { "host" => "100.64.0.9", "user" => "jon", "folders" => [ "/srv/media", "/srv/My Photos" ] }.merge(details)
      )
    end

    def installer(agent, shell)
      minted = @minted
      Resource::XixoAgent::Installer.new(agent, shell: shell, minter: ->(_tenant, name:) { minted << name && "minted-for-#{name}" })
    end
end
