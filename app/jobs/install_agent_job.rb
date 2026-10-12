class InstallAgentJob < ApplicationJob
  queue_as :sync

  def perform(resource_id, run_id)
    run = Run.find_by(id: run_id)
    agent = Resource::XixoAgent.find_by(id: resource_id)
    return run&.finished!(error: "the machine is gone, so nothing was installed") if agent.nil?

    key = agent.credentials.to_h["private_key"]
    agent.forget_key!
    return if run.nil?

    run.running!
    return run.finished!(error: "#{agent.key} was put away, so nothing was installed") if agent.archived_at.present?
    return run.finished!(error: "no SSH key was held, so nothing was installed") if key.blank?

    install(agent, run, key)
    run.finished!
    agent.check
  rescue StandardError => e
    run&.log_fail(e.message)
    run&.finished!(error: e.message)
    agent&.update_columns(checked_at: Time.current, check_error: Redaction.scrub("#{e.class}: #{e.message}"))
  ensure
    agent&.forget_key!
  end

  private

    def install(agent, run, key)
      address = address_for(agent)

      Resource::XixoAgent::Shell.open(address: address, port: port_for(agent), user: agent.details["user"].to_s,
                                      key: key, pinned: agent.host_key) do |shell|
        run.log_info("connected to #{agent.details['host']} as #{agent.details['user']}")
        Resource::XixoAgent::Installer.new(agent, shell: shell, tailnet: agent.on_tailnet?(address),
                                                  log: ->(said) { run.log_done(said) }).install!
      end
    end

    def address_for(agent)
      PublicAddress.address_for!(agent.details["host"].to_s, through: agent.through)
    rescue PublicAddress::Blocked, PublicAddress::Unresolvable => e
      raise Resource::Failed, e.message
    end

    def port_for(agent)
      port = (agent.details["port"].presence || 22).to_i
      raise Resource::Failed, "#{port} is not a port SSH listens on" unless port.between?(1, 65_535)

      port
    end
end
