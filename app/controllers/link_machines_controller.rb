class LinkMachinesController < ApplicationController
  include Granted

  skip_forgery_protection

  SAID = %w[hostname os arch folders writable details name off].freeze

  rate_limit to: 10, within: 1.hour, by: -> { request.remote_ip }, only: :create,
             with: -> { render status: :too_many_requests, json: { error: "slow_down", error_description: "too many machines added from this address. Wait an hour" } }

  def create
    grant.administer!("adds a machine")
    said = request.request_parameters.to_h.slice(*SAID)
    said["hostname"] = said["name"] if said["name"].present?
    added = LinkRequest.added!(said, grant: grant, remote_ip: request.remote_ip)
    held = added.request
    audited("add", "ok", "added #{held.hostname} over ssh", hostname: held.hostname, off: held.off)

    render status: :created, json: {
      device_code: added.device_code, enrollment_token: added.enrollment_token, name: held.hostname,
      links_as: Resource::Machine.free_key(held.hostname), url: "#{Tenant.origin(request)}/settings/resources",
      issuer: Current.tenant.issuer, plan: held.plan.map(&:to_h)
    }
  rescue LinkRequest::Refused, Resource::Failed => e
    render status: :unprocessable_content, json: { error: "refused", error_description: e.message }
  rescue Grant::Denied => e
    render status: :forbidden, json: { error: "access_denied", error_description: e.message }
  end

  def destroy
    grant.administer!("removes a machine")
    machine = Resource::Machine.active.find_by(key: params[:key])
    return render(status: :not_found, json: { error: "not_found", error_description: "no machine is linked as #{params[:key]}" }) if machine.nil?

    raise Resource::Failed, machine.errors.full_messages.to_sentence unless machine.put_away

    audited("remove", "ok", "removed #{machine.key} over ssh", key: machine.key)
    head :no_content
  rescue Resource::Failed => e
    render status: :unprocessable_content, json: { error: "refused", error_description: e.message }
  rescue Grant::Denied => e
    render status: :forbidden, json: { error: "access_denied", error_description: e.message }
  end

  private

    def audited(action, status, told, **arguments)
      AuditEvent.record(channel: "link", action: action, status: status, grant: grant, told: told,
                        context: Current.audit, arguments: arguments)
    end
end
