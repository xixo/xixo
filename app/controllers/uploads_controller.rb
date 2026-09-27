class UploadsController < ApplicationController
  include Granted

  def create
    file = params[:file]

    return unusable("no file was sent") unless file.respond_to?(:original_filename)

    landed = Intake.write!(
      path: params[:path].presence || file.original_filename,
      body: file.tempfile,
      unique: true,
      grant: grant
    )

    return already_there(landed.feed) if landed.duplicate

    render status: :accepted, json: {
      feed_id: landed.feed.id,
      type: landed.feed.type,
      mime: landed.staged.mime,
      path: landed.staged.path,
      analysis_id: landed.analysis.id
    }
  rescue Intake::Unusable => e
    unusable(e.message)
  end

  private

    def authorize
      super && grant.permit!("uris:catalog:write")
    rescue Grant::Denied => e
      refuse(Masks::Client::Unauthorized.new(e.message))
    end

    def already_there(feed)
      held = feed.reference || feed.staged

      render status: :ok, json: {
        duplicate: true,
        feed_id: feed.id,
        twin: held&.path || feed.title
      }
    end

    def unusable(message)
      render json: { error: message }, status: :unprocessable_entity
    end
end
