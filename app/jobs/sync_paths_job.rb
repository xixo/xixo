class SyncPathsJob < ApplicationJob
  queue_as :sync

  limits_concurrency to: 1, key: ->(_tenant_id, resource_id, *) { "sync-paths/#{resource_id}" }, duration: 15.minutes

  discard_on(Resource::Failed) do |job, error|
    Rails.logger.info("#{job.class.name} left #{job.arguments[1]} to its next walk: #{error.message.truncate(200)}")
  end

  def perform(_tenant_id, resource_id, paths)
    resource = Resource::Filesystem.active.find_by(id: resource_id)
    return if resource.nil?

    resource.looked_again!(Array(paths))
  end
end
