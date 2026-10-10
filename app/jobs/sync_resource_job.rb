class SyncResourceJob < ApplicationJob
  include JobIteration::Iteration
  include TrackedRun

  queue_as :sync

  gated_as "sync"

  rescue_from(StandardError) do |error|
    fail_run(error)
    abandon_sync
    raise error
  end

  retry_on Resource::Failed, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.fail_run(error)
    job.abandon_sync
  end

  rescue_from(Resource::Unusable) do |error|
    fail_run(error)
    abandon_sync
  end

  on_complete :release_sync

  def run_id
    arguments[2]
  end

  def build_enumerator(_tenant_id, resource_id, _run_id = nil, cursor:)
    resource = resource_for(resource_id)
    walk = walk_for(resource, cursor)

    objects = Enumerator.new do |yielder|
      started_at = cursor

      resource.each_page(cursor: cursor, walk: walk) do |page, next_cursor|
        page.each_with_index do |object, index|
          yielder.yield(object, index == page.size - 1 ? next_cursor : started_at)
        end

        started_at = next_cursor
      end
    end

    enumerator_builder.wrap(enumerator_builder, objects)
  end

  def abandon_sync
    resource = Resource.find_by(id: arguments[1])
    return if resource.nil?

    Resource::Walk.new(resource).abandon!
    resource.abandon_sync!
  end

  def gate_reference
    resource_for(arguments[1])
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def each_iteration(object, tenant_id, resource_id, _run_id = nil)
    return track_iteration if dry_run?

    kept(resource_for(resource_id), object)

    track_iteration
  end

  private

    def kept(resource, object)
      resource.keep!(object)
    rescue Resource::Skipped => e
      run&.log_skip("sync", e.message)
    end

    def release_sync
      return abandon_sync if stopped?
      return if @resource.nil?

      if dry_run?
        Resource::Walk.new(@resource).abandon!
        return @resource.release_sync!
      end

      gone = walk_for(@resource, :resumed).finish!(@resource.sync_started_at)
      run&.log_info("sync", "#{gone} no longer found at the source") if gone.positive?

      @resource.release_sync!
    end

    def walk_for(resource, cursor)
      @walk ||= cursor.nil? ? Resource::Walk.begin!(resource) : Resource::Walk.resume(resource)
    end

    def resource_for(resource_id)
      @resource ||= Resource.find(resource_id)
    end
end
