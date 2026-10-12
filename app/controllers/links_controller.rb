class LinksController < ActionController::API
  REFUSED = "That code is not one xixo is waiting on. Ask for a fresh one on the Resources page.\n".freeze
  UNSIGNED = "Linking up takes the machine's own token. Run xixo-link link on the machine after it enrolls.\n".freeze
  MOST_FOLDERS = Resource::Machine::MOST_FOLDERS

  rate_limit to: 30, within: 1.minute, by: -> { request.remote_ip },
             with: -> { plain("Too many tries from this address. Wait a minute.\n", :too_many_requests) }

  before_action :no_store
  before_action :awaited, except: :create

  def download
    build = Resource::Machine::Downloads.builds.find { |held| held.file == params[:file].to_s }
    return plain("There is no such build here.\n", :not_found) if build.nil?

    audited("download", "ok", "downloaded #{build.file}", file: build.file)
    send_file build.path, type: "application/octet-stream", disposition: "attachment", filename: "xixo-link"
  end

  def plist
    path = Resource::Machine::Downloads.plist
    return plain("There is no launch agent here.\n", :not_found) if path.nil?

    audited("download", "ok", "downloaded the launch agent", file: Resource::Machine::Downloads::PLIST)
    send_file path, type: "application/xml", disposition: "attachment", filename: Resource::Machine::Downloads::PLIST
  end

  def unit
    folders = Array(params[:folders]).first(MOST_FOLDERS)
    body = Resource::Machine::Installer.unit(user: params[:user].to_s, folders: folders)

    audited("download", "ok", "downloaded the service", file: Resource::Machine::Installer::UNIT_FILE)
    render plain: body, content_type: "text/plain"
  rescue Resource::Failed => e
    plain("#{e.message}\n", :unprocessable_content)
  end

  def create
    held = Resource::Machine::Caller.from(request, path: "/link")
    return refused(UNSIGNED, :unauthorized, "a machine tried to link up without a token xixo lets in") if held.nil?

    @grant = held.grant
    code = params[:code].to_s.strip
    return refused(REFUSED, :unauthorized, "a machine named no code it was waiting on") if Resource::Machine::Linking.pending(code).nil?

    machine = Resource::Machine::Linking.link!(code, held.claims.client_id)
    audited("link", "ok", "linked #{machine.key} as #{machine.client_id}", key: machine.key)

    plain("Linked up as #{machine.key}. Start xixo link and xixo shows it as linked within a minute.\n", :ok)
  rescue Resource::Refused => e
    refused("#{e.message.upcase_first}.\n", :unprocessable_content, e.message)
  end

  private

    def awaited
      @token = Resource::Machine::Linking.presented(request.authorization)
      return if Resource::Machine::Linking.pending(@token)

      refused(REFUSED, :unauthorized, "a download named no code xixo was waiting on")
    end

    def refused(text, status, why)
      audited(action_name == "create" ? "link" : "download", "denied", "was not let in", detail: why)
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
