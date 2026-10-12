class LinksController < ActionController::API
  REFUSED = "That code is not one xixo is waiting on. Ask for a fresh one on the Resources page.\n".freeze
  MOST_FOLDERS = Resource::Machine::MOST_FOLDERS

  rate_limit to: 30, within: 1.minute, by: -> { request.remote_ip },
             with: -> { plain("Too many tries from this address. Wait a minute.\n", :too_many_requests) }

  before_action :no_store
  before_action :awaited

  def download
    build = Resource::Machine::Downloads.builds.find { |held| held.file == params[:file].to_s }
    return plain("There is no such build here.\n", :not_found) if build.nil?

    send_file Resource::Machine::Downloads.binary(build.file), type: "application/octet-stream", disposition: "attachment", filename: "xixo-link"
  end

  def plist
    path = Resource::Machine::Downloads.plist
    return plain("There is no launch agent here.\n", :not_found) if path.nil?

    send_file path, type: "application/xml", disposition: "attachment", filename: Resource::Machine::Downloads::PLIST
  end

  def unit
    folders = Array(params[:folders]).first(MOST_FOLDERS)
    body = Resource::Machine::Installer.unit(user: params[:user].to_s, folders: folders)

    render plain: body, content_type: "text/plain"
  rescue Resource::Failed => e
    plain("#{e.message}\n", :unprocessable_content)
  end

  def create
    machine = Resource::Machine::Linking.link!(@token, params[:client_id].to_s.strip)
    Rails.logger.info "linked #{machine.key} as #{machine.client_id}"

    plain("Linked up as #{machine.key}. Start xixo link and xixo shows it as linked within a minute.\n", :ok)
  rescue Resource::Refused => e
    plain("#{e.message.upcase_first}.\n", :unprocessable_content)
  end

  private

    def awaited
      @token = Resource::Machine::Linking.presented(request.authorization)
      plain(REFUSED, :unauthorized) if Resource::Machine::Linking.pending(@token).nil?
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end

    def plain(text, status)
      render plain: text, status: status, content_type: "text/plain"
    end
end
