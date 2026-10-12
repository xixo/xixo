class InstallLinkJob < ApplicationJob
  queue_as :sync

  def perform(resource_id, run_id)
    run = Run.find_by(id: run_id)
    machine = Resource::Machine.find_by(id: resource_id)
    return run&.finished!(error: "the machine is gone, so nothing was installed") if machine.nil?

    key = machine.credentials.to_h["private_key"]
    machine.forget_key!
    return if run.nil?

    run.running!
    return run.finished!(error: "#{machine.key} was put away, so nothing was installed") if machine.archived_at.present?
    return run.finished!(error: "no SSH key was held, so nothing was installed") if key.blank?

    install(machine, run, key)
    run.finished!
    machine.check
  rescue StandardError => e
    run&.log_fail(e.message)
    run&.finished!(error: e.message)
    machine&.update_columns(checked_at: Time.current, check_error: Redaction.scrub(Resource.told(e)))
  ensure
    machine&.forget_key!
  end

  private

    def install(machine, run, key)
      address = address_for(machine)

      Resource::Machine::Shell.open(address: address, port: port_for(machine), user: machine.details["user"].to_s,
                                      key: key, pinned: machine.host_key) do |shell|
        run.log_info("connected to #{machine.details['host']} as #{machine.details['user']}")
        Resource::Machine::Installer.new(machine, shell: shell, tailnet: machine.on_tailnet?(address),
                                                  log: ->(said) { run.log_done(said) }).install!
      end
    end

    def address_for(machine)
      PublicAddress.address_for!(machine.details["host"].to_s, through: machine.through)
    rescue PublicAddress::Blocked, PublicAddress::Unresolvable => e
      raise Resource::Failed, e.message
    end

    def port_for(machine)
      port = (machine.details["port"].presence || 22).to_i
      raise Resource::Failed, "#{port} is not a port SSH listens on" unless port.between?(1, 65_535)

      port
    end
end
