class InstallAgentJob < ApplicationJob
  queue_as :sync

  discard_on ActiveRecord::RecordNotFound

  def perform(resource_id, run_id)
    agent = Resource::XixoAgent.active.find(resource_id)
    run = Run.find(run_id)
    key = agent.credentials.to_h["private_key"]
    run.running!

    return run.finished!(error: "no SSH key was held, so nothing was installed") if key.blank?

    agent.forget_key!
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
      Resource::XixoAgent::Shell.open(address: address_for(agent), port: port_for(agent), user: agent.details["user"].to_s,
                                      key: key, pinned: agent.details["host_key"]) do |shell|
        run.log_info("connected to #{agent.details['host']} as #{agent.details['user']}")
        Resource::XixoAgent::Installer.new(agent, shell: shell, log: ->(said) { run.log_done(said) }).install!
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
