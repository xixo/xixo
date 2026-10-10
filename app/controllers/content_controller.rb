class ContentController < ApplicationController
  include Granted

  CHUNK = 64.kilobytes
  INLINE = %w[
    image/png image/jpeg image/gif image/webp image/avif image/bmp
    application/pdf application/json text/plain text/markdown text/csv
  ].freeze
  SANDBOX = "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'".freeze

  def show
    reference = find_reference or return head :not_found
    type = reference.content_type
    kind = Rack::MediaType.type(type).to_s

    response.headers["Content-Type"] = type
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = SANDBOX unless kind == "application/pdf"
    response.headers["Content-Disposition"] =
      ActionDispatch::Http::ContentDisposition.format(
        disposition: inline?(kind) ? "inline" : "attachment",
        filename: reference.filename
      )

    stream(reference.download)
  rescue Resource::Failed => e
    render plain: Redaction.scrub(e.message), status: :bad_gateway
  end

  private

    def authorize
      super && grant.permit!("xixo:catalog:read")
    rescue Grant::Denied => e
      refuse(Masks::Client::Unauthorized.new(e.message))
    end

    def inline?(kind)
      return false if params[:download]

      INLINE.include?(kind) || MimeType.video?(kind) || MimeType.audio?(kind)
    end

    def find_reference
      Reference.reachable_by(grant).where(feed: Feed.readable_by(grant)).find_by(id: params[:id])
    end

    def stream(io)
      self.response_body = Enumerator.new do |yielder|
        while (chunk = io.read(CHUNK))
          yielder << chunk
        end
      ensure
        io.close if io.respond_to?(:close)
      end
    end
end
