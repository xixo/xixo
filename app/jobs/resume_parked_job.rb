class ResumeParkedJob < ApplicationJob
  queue_as :analysis

  BATCH = 50
  AGAIN_IN = 1.minute

  limits_concurrency to: 1, key: ->(*) { "resume-parked/#{Current.tenant&.id}" }, duration: 5.minutes

  def perform(machine_id = nil)
    room = BATCH - Analysis.where(status: "queued").count
    return if room <= 0

    held = servable(machine_id).order(:id).limit(room + 1).to_a
    held.first(room).each { |analysis| resume(analysis) }

    again(machine_id) if held.size > room
  end

  private

    def again(machine_id)
      self.class.set(wait: AGAIN_IN).perform_later(machine_id)
    end

    def resume(analysis)
      feed = analysis.feed
      return analysis.cancel! if feed.nil?

      AnalyzeFeedJob.enqueue(feed, analysis) if analysis.unparked!
    end

    def servable(machine_id)
      online = Resource::Machine.active.order(:id).select(&:connected?)
      pool = online.select(&:reads_for_others?)
      pooled = pool.flat_map(&:extractors)
      asked = machine_id ? online.select { |machine| machine.id == machine_id.to_i } : online

      waits = asked.flat_map do |machine|
        [
          [ machine.id, machine.extractors + (machine.lends? ? pooled : []) ],
          ([ nil, machine.extractors ] if pool.include?(machine))
        ].compact
      end

      held = waits.filter_map { |on, kinds| served(on, kinds.uniq) }
      held << stranded if machine_id.nil?
      held.reduce(:or) || Analysis.none
    end

    def stranded
      Analysis.parked.where.not(waits_on_id: nil).where.not(waits_on_id: Resource::Machine.active.select(:id))
    end

    def served(on, kinds)
      Analysis.parked.where(waits_on_id: on, waits_for: [ nil, *kinds ]) if kinds.any?
    end
end
