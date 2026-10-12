class EnrollLocalAgentJob < ApplicationJob
  queue_as :sync
  across_tenants!

  WANTED = "wanted".freeze
  TOKEN = "token".freeze
  CLIENT = "client_id".freeze
  CLIENT_ID = /\A[\w.:-]{1,200}\z/
  REPLACED_AFTER = (Resource::XixoAgent::Enrollment::LASTS - 60).seconds

  def self.handoff
    ENV["XIXO_LOCAL_AGENT"].presence&.then { |path| Pathname.new(path) }
  end

  def perform
    root = self.class.handoff
    return if root.nil? || !plain_directory?(root)

    Tenant.find_each do |tenant|
      dir = root.join(tenant.subdomain)
      next unless plain_directory?(dir)

      Tenant.switch(tenant) { tend(tenant, dir) }
    end
  end

  private

    def tend(tenant, dir)
      agent = Resource::XixoAgent.local!

      bind(agent, dir)
      offer(tenant, agent, dir)
    end

    def bind(agent, dir)
      said = read_plain(dir.join(CLIENT))
      return unless said&.match?(CLIENT_ID)

      agent.bound!(said)
    end

    def offer(tenant, agent, dir)
      return unless regular?(dir.join(WANTED))

      token = dir.join(TOKEN)
      return if regular?(token) && File.lstat(token).mtime > REPLACED_AFTER.ago

      minted = Resource::XixoAgent::Enrollment.mint(tenant, name: "#{agent.name}, #{tenant.subdomain}")
      write_plain(dir, TOKEN, minted)
    end

    def read_plain(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        file.stat.file? ? file.read(256).to_s.strip : nil
      end
    rescue SystemCallError
      nil
    end

    def write_plain(dir, name, content)
      written = dir.join(".#{name}.#{SecureRandom.hex(8)}")
      owner = File.lstat(dir)

      File.open(written, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(content)
        handed(file, owner)
      end
      File.rename(written, dir.join(name))
    ensure
      FileUtils.rm_f(written) if written && File.exist?(written)
    end

    def handed(file, owner)
      file.chown(owner.uid, owner.gid)
    rescue Errno::EPERM
      nil
    end

    def regular?(path)
      File.lstat(path).file?
    rescue SystemCallError
      false
    end

    def plain_directory?(path)
      File.lstat(path).directory?
    rescue SystemCallError
      false
    end
end
