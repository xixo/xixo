class Resource
  class Walk
    FULL = "full".freeze
    CHANGES = "changes".freeze
    FULL_EVERY = 1.day

    attr_reader :resource
    attr_accessor :run

    class << self
      def begin!(resource)
        new(resource).tap do |walk|
          mode = walk.chosen_mode
          resource.update_columns(sync_state: resource.sync_state.to_h.merge("walk" => { "mode" => mode }))
        end
      end

      def resume(resource)
        held = resource.sync_state.to_h["walk"]

        held.present? ? new(resource) : begin!(resource)
      end

      def full(resource)
        new(resource, kept: { "mode" => FULL })
      end
    end

    def initialize(resource, kept: nil)
      @resource = resource
      @kept = kept
    end

    def mode
      state["mode"] || FULL
    end

    def full?
      mode == FULL
    end

    def since
      full? ? nil : resource.sync_state.to_h["checkpoint"]
    end

    def chosen_mode
      checkpoint = resource.sync_state.to_h["checkpoint"]
      fresh = resource.walked_at.present? && resource.walked_at > FULL_EVERY.ago

      resource.class.walks_changes? && checkpoint.present? && fresh ? CHANGES : FULL
    end

    def start_over!
      write("mode" => FULL, "reached" => nil)
    end

    def reached(checkpoint = nil, first: false)
      return if first && state["reached"].present?

      write("reached" => checkpoint || yield)
    end

    def partial!
      write("partial" => true)
    end

    def partial?
      state["partial"] == true
    end

    def gone(locator_keys)
      keys = Array(locator_keys).compact
      return 0 if keys.empty?

      originals.where(locator_key: keys).update_all(gone_at: Time.current)
    end

    def skipped(locator_key, said)
      run&.log_skip("sync", locator_key, "skipped", said)
    end

    def finish!(started)
      gone = full? && !partial? && started ? unseen_since(started) : 0
      settled = resource.sync_state.to_h.except("walk")
      settled["checkpoint"] = state["reached"] if state.key?("reached")

      resource.update_columns(sync_state: settled, walked_at: full? && !partial? ? Time.current : resource.walked_at)
      gone
    end

    def abandon!
      resource.update_columns(sync_state: resource.sync_state.to_h.except("walk"))
    end

    def write(changes)
      if @kept
        @kept = @kept.merge(changes).compact
      else
        walk = state.merge(changes).compact
        resource.update_columns(sync_state: resource.sync_state.to_h.merge("walk" => walk))
      end
    end

    private

      def state
        @kept || resource.sync_state.to_h["walk"].to_h
      end

      def originals
        Reference.originals.where(resource_id: resource.id, gone_at: nil)
      end

      def unseen_since(started)
        return 0 unless resource.class.notices_what_is_gone?

        originals.where.not(seen_at: nil).where(seen_at: ...started).update_all(gone_at: Time.current)
      end
  end
end
