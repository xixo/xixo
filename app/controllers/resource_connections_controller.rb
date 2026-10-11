class ResourceConnectionsController < ApplicationController
  include Granted

  HELD = "resource_connecting".freeze
  WINDOW = 15.minutes
  PROMPTS = %w[login consent].freeze

  def show
    resource = connectable(params[:id])

    return missing if resource.nil?

    begin!(resource, prompt: params[:prompt].presence_in(PROMPTS))
  end

  def callback
    held = session.delete(HELD).to_h

    return landed(nil, "that connection expired or was started in another browser — start it again") unless usable?(held)

    resource = connectable(held["resource_id"])

    return landed(nil, "that resource is gone") if resource.nil?

    connected = delegations.finish(params: request.query_parameters, started: held)

    return landed(resource, "masks connected somebody other than who started it") unless connected.subject == grant.subject

    resource.connect!(connected, by: grant.subject)
    resource.check

    audit(resource, "ok")

    landed(resource, nil)
  rescue Delegations::Refused => e
    return begin!(resource, prompt: "login", retried: true) if e.signed_in_again? && resource && !held["retried"]

    audit(resource, "denied", e.message) if resource

    landed(resource, e.description.presence || e.code)
  rescue Delegations::Unavailable, Tenant::Unconfigured => e
    landed(resource, "masks could not be reached — #{e.message}")
  end

  private

    def authorize
      super && grant.permit!("xixo:resources:command")
    rescue Grant::Denied => e
      refuse(Masks::Client::Unauthorized.new(e.message))
    end

    def connectable(id)
      resource = Resource.visible_to(grant).managed_by(grant).find_by(id: id)

      resource if resource&.delegated?
    end

    def delegations
      Delegations.for(current_tenant, origin: Current.origin)
    end

    def begin!(resource, prompt: nil, retried: false)
      started = delegations.start(provider: resource.provider_key, prompt: prompt)

      session[HELD] = started.merge(
        "resource_id" => resource.id,
        "tenant_id" => current_tenant.id,
        "subject" => grant.subject,
        "expires_at" => WINDOW.from_now.to_i,
        "retried" => retried
      )

      redirect_to started["url"], allow_other_host: true
    rescue Tenant::Unconfigured => e
      landed(resource, e.message)
    end

    def usable?(held)
      held.present? &&
        held["tenant_id"] == current_tenant.id &&
        held["subject"] == grant.subject &&
        held["expires_at"].to_i > Time.current.to_i
    end

    def landed(resource, refusal)
      path = resource ? "/settings/resources/#{resource.id}" : "/settings/resources"
      query = refusal ? "?#{URI.encode_www_form(connect_error: Redaction.scrub(refusal.to_s).truncate(300))}" : ""

      redirect_to "#{path}#{query}", allow_other_host: false
    end

    def missing
      render plain: "there is no resource here that connects through masks", status: :not_found
    end

    def audit(resource, status, detail = nil)
      AuditEvent.record(
        channel: "connect", action: "connect", status: status, scope: "xixo:resources:command",
        grant: Current.grant, context: Current.audit, detail: detail,
        told: "connected #{resource.key} through #{resource.provider_key}",
        arguments: { type: resource.class.sti_name, key: resource.key, provider: resource.provider_key }
      )
    end
end
