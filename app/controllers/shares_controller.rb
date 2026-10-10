class SharesController < ApplicationController
  include Granted

  ADDRESS = %r{\Ahttps?://\S+\z}i
  RENDERED = [ MimeType::DEFAULT, "text/html" ].freeze

  def create
    files = Array(params[:files]).select { |file| file.respond_to?(:original_filename) }

    redirect_to files.any? ? files_landed(files) : words_landed, status: :see_other
  end

  private

    def authorize
      super && grant.permit!("xixo:catalog:write")
    rescue Grant::Denied => e
      refuse(Masks::Client::Unauthorized.new(e.message))
    end

    def verified_request?
      super || from_this_device?
    end

    def from_this_device?
      origin = request.origin

      return false if origin.present? && origin != "null" && origin != request.base_url

      case request.headers["Sec-Fetch-Site"]
      when "none", "same-origin" then true
      when nil then origin == request.base_url
      else false
      end
    end

    def refuse(error)
      return super if presented?

      redirect_to masks_signed_in? ? "/?shared=denied" : masks_login_url(return_to: "/"), status: :see_other

      false
    end

    def files_landed(files)
      at = Time.current
      taken = Set.new
      tally = { kept: [], twins: [], refused: 0 }

      files.each_with_index do |file, index|
        path = Intake.filed("shared", file.original_filename, at: at)
        path = path.sub(/(\.[^.\/]*)?\z/) { "-#{index + 1}#{Regexp.last_match(1)}" } unless taken.add?(path)

        landed = Intake.write!(path: path, body: file.tempfile, unique: true, grant: grant)

        tally[landed.duplicate ? :twins : :kept] << landed.feed.id
      rescue Intake::Unusable
        tally[:refused] += 1
      end

      held = tally[:kept] + tally[:twins]

      if held.one? && tally[:refused].zero?
        return "/items/#{held.first}?#{{ shared: tally[:kept].any? ? 'kept' : 'twin' }.to_query}"
      end

      "/?#{{ shared: 'files', kept: tally[:kept].size, twins: tally[:twins].size,
             refused: tally[:refused] }.to_query}"
    end

    def words_landed
      title = params[:title].to_s.strip
      text = params[:text].to_s.strip
      address = params[:url].to_s.strip.presence || text[ADDRESS]

      return address_landed(address, title, text) if address
      return note_landed(title, text) if text.present? || title.present?

      "/?shared=nothing"
    end

    def address_landed(address, title, text)
      uri = PublicAddress.permitted!(address)

      if fetched?(uri) && Resource.stores.exists?
        FetchUrlJob.start!(current_tenant.id, uri.to_s)

        return "/?shared=download"
      end

      browser = Resource.browser(grant)

      return linked(title, text, address) if browser.nil?

      SnapshotUrlJob.start!(browser.tenant_id, browser, uri.to_s)

      "/?shared=page"
    rescue PublicAddress::Blocked, PublicAddress::Unresolvable
      linked(title, text, address)
    end

    def linked(title, text, address)
      note_landed(title, [ text, address ].compact_blank.uniq.join("\n\n"))
    end

    def fetched?(uri)
      RENDERED.exclude?(MimeType.for_filename(uri.path))
    end

    def note_landed(title, body)
      landed = Intake.note!(body.presence || title, title: title.presence)

      "/items/#{landed.feed.id}?shared=note"
    rescue Intake::Unusable, Resource::Failed
      "/?shared=refused"
    end
end
