class MoveFilesJob < ApplicationJob
  include JobIteration::Iteration
  include Gated

  ANNOUNCED_EVERY = 2.seconds

  queue_as :move

  gated_as "move"

  self.job_iteration_max_job_runtime = 5.minutes

  rescue_from(Resource::Unusable) do |error|
    run&.finished!(error: error.message)
  end

  retry_on Resource::Offline, wait: 2.minutes, attempts: 30 do |job, error|
    job.run&.finished!(error: "#{error.message}. The files not moved yet stay where they are. Start the move " \
                              "again once both machines are connected")
  end

  on_complete :settle

  def build_enumerator(_tenant_id, run_id, shard, shards, cursor:)
    waiting = Move.waiting.where(run_id: run_id).where("moves.id % ? = ?", shards.to_i, shard.to_i)

    enumerator_builder.active_record_on_records(waiting, cursor: cursor)
  end

  def each_iteration(move, *)
    stop! if run.nil? || run.halted?
    raise Resource::Offline, "#{move.source.machine.key} is not connected" unless move.source.machine.connected?
    raise Resource::Offline, "#{move.destination.machine.key} is not connected" unless move.destination.machine.connected?

    move.carry!
    move.status == "done" ? moved! : run.log_fail(move.path, move.error)
  end

  def run
    return @run if defined?(@run)

    @run = Run.find_by(id: arguments[1])
  end

  private

    def moved!
      run.progressed!(1)
      return if @announced_at && @announced_at > ANNOUNCED_EVERY.ago

      @announced_at = Time.current
      run.announce!
    end

    def settle
      return if run.nil? || !run.open?
      return if Move.waiting.where(run_id: run.id).exists?

      held = Move.progress(run.id)
      return run.finished! if held.files_failed.zero?

      run.finished!(error: "#{held.files_failed} of #{held.files} files stayed where they were. The log names each one")
    end
end
