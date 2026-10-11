module Health
  LATE_QUEUE = 10.minutes

  class << self
    def checks
      { database: database?, search: SearchIndex.healthy?, queue: queue?, worker: worker? }
    end

    def quiet_worker
      Integer(ENV.fetch("XIXO_WORKER_QUIET_SECONDS", SolidQueue.process_alive_threshold.to_i)).seconds
    end

    private

      def database?
        safely { ActiveRecord::Base.connection.select_value("SELECT 1") == 1 }
      end

      def queue?
        safely do
          oldest = SolidQueue::ReadyExecution.order(:job_id).pick(:created_at)
          oldest.nil? || oldest > LATE_QUEUE.ago
        end
      end

      def worker?
        return true if ENV["SOLID_QUEUE_IN_PUMA"].present?

        safely do
          heartbeat = SolidQueue::Process.where(kind: "Worker").maximum(:last_heartbeat_at)
          heartbeat.present? && heartbeat > quiet_worker.ago
        end
      end

      def safely
        yield
      rescue StandardError
        false
      end
  end
end
