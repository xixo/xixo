class LinksController < ActionController::API
  UNSIGNED = "Linking up takes the machine's own token.\n".freeze
  UNKNOWN = "xixo knows no machine linked as this client.\n".freeze
  UNKNOWN_REQUEST = "xixo is not waiting on that request. Run the command again.\n".freeze
  STARTED = %w[hostname os arch folders writable details].freeze

  rate_limit to: 30, within: 1.minute, by: -> { request.remote_ip }, name: "minute",
             with: -> { plain("Too many tries from this address. Wait a minute.\n", :too_many_requests) }
  rate_limit to: 10, within: 1.hour, by: -> { request.remote_ip }, name: "start", only: :start,
             with: -> { refused_json("slow_down", "too many machines asked to link up from this address. Wait an hour", :too_many_requests) }

  before_action :no_store

  def script
    body = Resource::Machine::Script.new(xixo: Tenant.origin(request), issuer: Current.tenant.issuer).to_s

    render plain: body, content_type: "text/x-shellscript"
  rescue Tenant::Unconfigured
    plain("echo 'xixo link: this xixo is not connected to masks yet.' >&2; exit 1\n", :service_unavailable)
  end

  def download
    file = Resource::Machine::Downloads::FILES.find { |held| held == params[:file] }
    build = Resource::Machine::Downloads.served(file) if file
    return plain("There is no such build here.\n", :not_found) if build.nil?

    send_file build.path, type: "application/octet-stream", disposition: "attachment", filename: build.name
  end

  def plist
    served(Resource::Machine::Downloads.plist, Resource::Machine::Downloads::PLIST, "application/xml")
  end

  def unit
    served(Resource::Machine::Downloads.unit, Resource::Machine::Downloads::UNIT, "text/plain")
  end

  def update_unit
    served(Resource::Machine::Downloads.update_unit, Resource::Machine::Downloads::UPDATE_UNIT, "text/plain")
  end

  def update_path
    served(Resource::Machine::Downloads.update_path, Resource::Machine::Downloads::UPDATE_PATH, "text/plain")
  end

  def start
    said = request.request_parameters.to_h.slice(*STARTED)
    started = LinkRequest.start!(said, remote_ip: request.remote_ip)
    held = started.request
    audited("request", "ok", "asked to link up #{held.hostname}", hostname: held.hostname)

    render status: :created, json: {
      device_code: started.device_code, user_code: held.user_code,
      verification_uri: "#{Tenant.origin(request)}/link",
      verification_uri_complete: "#{Tenant.origin(request)}/link/#{held.user_code}",
      expires_in: LinkRequest::LASTS.to_i, interval: LinkRequest::POLLED_EVERY
    }
  rescue LinkRequest::Refused => e
    refused_json("slow_down", e.message, :too_many_requests)
  end

  def token
    held = LinkRequest.presented(params[:device_code])
    return refused_json("expired_token", "xixo is not waiting on that request. Run the command again", :bad_request) if held.nil?

    answered = held.polled!
    return refused_json(answered.to_s, told(answered), :bad_request) if answered.is_a?(Symbol)

    audited("request", "ok", "handed #{held.hostname} its enrollment token", hostname: held.hostname)
    render json: { enrollment_token: answered, name: held.hostname }
  end

  def show
    held = signed
    return if held.nil?
    return plain(UNKNOWN, :not_found) if held.machine.nil?

    plain("Linked up as #{held.machine.key}.\n", :ok)
  end

  def create
    held = signed
    return if held.nil?

    @grant = held.grant
    request_held = LinkRequest.presented(params[:device_code])
    return refused(UNKNOWN_REQUEST, :unauthorized, "a machine named no request xixo was waiting on") if request_held.nil?

    machine = request_held.link!(held.claims.client_id)
    audited("link", "ok", "linked #{machine.key} as #{machine.client_id}", key: machine.key)

    plain("Linked up as #{machine.key}.\n", :ok)
  rescue LinkRequest::Refused => e
    refused("#{e.message.upcase_first}.\n", :unprocessable_content, e.message)
  end

  private

    def signed
      held = Resource::Machine::Caller.from(request, path: "/link")
      return held if held

      refused(UNSIGNED, :unauthorized, "a machine tried to link up without a token xixo lets in")
      nil
    end

    def served(path, file, type)
      return plain("There is no #{file} here.\n", :not_found) if path.nil?

      send_file path, type: type, disposition: "attachment", filename: file
    end

    def told(answered)
      {
        authorization_pending: "waiting for an administrator to approve this machine",
        slow_down: "asking too often. Wait #{LinkRequest::POLLED_EVERY} seconds between tries",
        access_denied: "an administrator denied this machine",
        expired_token: "the request ran out. Run the command again"
      }.fetch(answered)
    end

    def refused_json(error, description, status)
      render status: status, json: { error: error, error_description: description }
    end

    def refused(text, status, why)
      audited("link", "denied", "was not let in", detail: why)
      plain(text, status)
    end

    def audited(action, status, told, detail: nil, **arguments)
      AuditEvent.record(
        channel: "link", action: action, status: status, grant: @grant, told: told, detail: detail,
        context: { remote_ip: request.remote_ip, request_id: request.request_id }, arguments: arguments
      )
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end

    def plain(text, status)
      render plain: text, status: status, content_type: "text/plain"
    end
end
