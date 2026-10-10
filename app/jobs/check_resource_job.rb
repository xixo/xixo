class CheckResourceJob < ApplicationJob
  queue_as :sync

  discard_on ActiveRecord::RecordNotFound

  def perform(resource_id)
    resource = Resource.due_for_check.or(Resource.attended.active.probing).find_by(id: resource_id)
    return if resource.nil?

    resource.probe
  end
end
