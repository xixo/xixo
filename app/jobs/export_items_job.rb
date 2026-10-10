class ExportItemsJob < ApplicationJob
  include JobIteration::Iteration
  include TrackedRun

  queue_as :export

  gated_as "export"

  retry_on Resource::Failed, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.fail_run(error)
  end

  def run_id
    arguments[3]
  end

  def build_enumerator(_tenant_id, destination_id, selector, _run_id = nil, cursor:)
    Resource.find(destination_id).storage!

    enumerator_builder.build_array_enumerator(select(selector).pluck(:id), cursor: cursor)
  end

  def each_iteration(feed_id, _tenant_id, destination_id, _selector, _run_id = nil)
    destination = Resource.find(destination_id)
    feed = Feed.find_by(id: feed_id)
    source = feed&.source_for(destination)

    return track_iteration if source.nil?

    copy = feed.copy_at(destination)

    return track_iteration if copy && !copy.stale_against?(source)

    path = copy&.locator_key || source.path
    locator = destination.upload(path, source.download)

    Reference.record!(
      feed: feed, resource: destination, locator: locator, locator_key: path,
      source_version: source.version
    )

    track_iteration
  end

  private

    def select(selector)
      Feed.referenced.readable_to(selector["reader"]).matching(selector)
    end
end
