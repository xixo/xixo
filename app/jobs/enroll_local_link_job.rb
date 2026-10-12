class EnrollLocalLinkJob < ApplicationJob
  queue_as :sync
  across_tenants!

  WANTED = "wanted".freeze
  TOKEN = "token".freeze
  CLIENT = "client_id".freeze
  CLIENT_ID = /\A[\w.:-]{1,200}\z/
  REPLACED_AFTER = (Resource::Machine::Enrollment::LASTS - 60).seconds
  BOUND_WITHIN = (Resource::Machine::Enrollment::LASTS + 120).seconds

  def self.handoff
    ENV["XIXO_LOCAL_LINK"].presence&.then { |path| Pathname.new(path) }
  end

  def perform
    root = self.class.handoff
    return if root.nil? || !plain_directory?(root)

    Tenant.find_each do |tenant|
      dir = root.join(tenant.subdomain)
      next unless tenant.connected? && plain_directory?(dir)

      Tenant.switch(tenant) { tend(tenant, dir) }
    end
  end

  private

    def tend(tenant, dir)
      machine = Resource::Machine.local!

      bind(machine, dir)
      offer(tenant, machine, dir)
    end

    def bind(machine, dir)
      said = read_plain(dir.join(CLIENT))
      return if !said&.match?(CLIENT_ID) || machine.client_id == said

      unless awaited?(machine)
        return refuse(machine, "xixo link beside the server named the client #{said}, which no enrollment token " \
                             "xixo handed it in the last #{BOUND_WITHIN.inspect} made. Clear xixo link's state in " \
                             "/var/lib/xixo-link and restart it to enroll it again")
      end

      if Resource::Machine.where.not(id: machine.id).exists?([ "resources.details ->> 'client_id' = ?", said ])
        return refuse(machine, "xixo link beside the server named the client #{said}, which another machine is " \
                             "enrolled as")
      end

      machine.bound!(said)
    end

    def awaited?(machine)
      minted = Time.iso8601(machine.details.to_h[Resource::Machine::MINTED].to_s)
      minted > BOUND_WITHIN.ago
    rescue ArgumentError
      false
    end

    def refuse(machine, said)
      Rails.logger.warn("EnrollLocalLinkJob: #{said}")
      machine.update_columns(checked_at: Time.current, check_error: said) unless machine.check_error == said
    end

    def offer(tenant, machine, dir)
      return unless regular?(dir.join(WANTED))

      token = dir.join(TOKEN)
      return if regular?(token) && File.lstat(token).mtime > REPLACED_AFTER.ago

      minted = Resource::Machine::Enrollment.mint(tenant, name: "#{machine.name}, #{tenant.subdomain}")
      machine.update!(details: machine.details.to_h.merge(Resource::Machine::MINTED => Time.current.utc.iso8601))
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
