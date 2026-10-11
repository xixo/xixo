class HealthController < ActionController::Base
  LATE_QUEUE = 10.minutes
  QUIET_WORKER = 3 * SolidQueue.process_heartbeat_interval

  def show
    checks = { database: database?, search: search?, queue: queue?, worker: worker? }
    serving = checks[:database] && checks[:search]

    render json: { status: serving ? "ok" : "failing", checks: checks.transform_values { |ok| ok ? "ok" : "failing" } },
           status: serving ? :ok : :service_unavailable
  end

  private

    def database?
      ActiveRecord::Base.connection.select_value("SELECT 1") == 1
    rescue StandardError
      false
    end

    def search?
      SearchIndex.healthy?
    end

    def queue?
      oldest = SolidQueue::ReadyExecution.minimum(:created_at)
      oldest.nil? || oldest > LATE_QUEUE.ago
    rescue StandardError
      false
    end

    def worker?
      return true if ENV["SOLID_QUEUE_IN_PUMA"].present?

      heartbeat = SolidQueue::Process.where(kind: "Worker").maximum(:last_heartbeat_at)
      heartbeat.present? && heartbeat > QUIET_WORKER.ago
    rescue StandardError
      false
    end
end
