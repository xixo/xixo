class Resource
  class Machine
    module Updates
      PROTOCOL = 1
      ACCEPTED_PROTOCOLS = ((PROTOCOL - 1)..PROTOCOL)
      OFFER_LASTS = 10.minutes
      ACTIONS = %w[update_now pause resume first roll_back].freeze
      STATES = %w[server manual paused ahead waiting_for_xixo current unknown updating held waiting offline].freeze

      def updates?
        details.to_h["updates"] != false
      end

      def updates_itself?
        !local? && Hello::UPDATES.include?(machine["updates"])
      end

      def release
        Downloads.version
      end

      def protocol
        machine["protocol"].to_i
      end

      def serial
        machine["serial"]
      end

      def ahead?
        heard_from? && protocol > PROTOCOL
      end

      def current?
        build = Downloads.build_for(machine["os"], machine["arch"])
        return nil if build.nil? || machine["sha256"].blank?

        machine["sha256"] == build.sha256 && current_mac_reader?
      end

      def wants_update?
        updates? && updates_itself? && !ahead? && current? == false
      end

      def update_offer(staged: true)
        return unless updates? && updates_itself? && !ahead?

        build = Downloads.build_for(machine["os"], machine["arch"])
        version = release
        return if build.nil? || version.nil? || current?
        return if staged && !LinkRollout.allows?(self)

        offer = { "version" => version, "sha256" => build.sha256, **Downloads.signed(build).to_h }
        reader = mac_reader_build
        offer["mac_reader"] = reader.sha256 if reader
        offer
      end

      def offer_update!(staged: true)
        return offer_roll_back! if ahead?

        offer = update_offer(staged: staged)
        return nil if offer.nil?

        LinkChannel.broadcast_to(self, { "update" => offer })
        merge_details!("offered" => offer.slice("version", "sha256", "release").merge("at" => Time.current.utc.iso8601))
        offer
      end

      def roll_back_offer
        return unless updates? && updates_itself?

        within = held_releases.select { |held| ACCEPTED_PROTOCOLS.cover?(held["protocol"].to_i) && held["sha256"] != machine["sha256"] }
        within.max_by { |held| held["serial"].to_i }&.slice("version", "sha256", "release")
      end

      def release_before
        return unless updates? && updates_itself?

        held_releases.select { |held| held["sha256"] != machine["sha256"] }.max_by { |held| held["serial"].to_i }&.slice("version", "sha256", "release")
      end

      def offer_roll_back!(to = roll_back_offer)
        return nil if to.nil?

        LinkChannel.broadcast_to(self, { "roll_back" => to })
        merge_details!("offered" => to.merge("at" => Time.current.utc.iso8601, "back" => true))
        to
      end

      def held_releases
        Array(machine["releases"]).select { |held| held.is_a?(Hash) }
      end

      def set_updates!(on)
        update!(details: details.to_h.merge("updates" => on == true))
        offer_update! if on
        announce!
      end

      def updates_done
        details.to_h.dig("updated", "count").to_i
      end

      def last_updated_at
        Time.iso8601(details.to_h.dig("updated", "at").to_s)
      rescue ArgumentError
        nil
      end

      def last_rollback
        held = details.to_h["rollback"]
        held if held.is_a?(Hash)
      end

      def on?(rollout)
        return machine["release"] == rollout.release if machine["release"].present?

        current? == true
      end

      def rollback_from(rollout)
        held = last_rollback
        return nil if held.nil? || held["at"].blank?

        build = Downloads.build_for(machine["os"], machine["arch"])
        return nil if build.nil? || held["sha256"] != build.sha256
        return nil if Time.iso8601(held["at"]) <= rollout.phase_at

        held
      rescue ArgumentError
        nil
      end

      def update_state
        return "server" if local?
        return "offline" unless connected?
        return "manual" unless updates_itself?
        return "paused" unless updates?
        return (roll_back_offer ? "ahead" : "waiting_for_xixo") if ahead?
        return "unknown" if current?.nil?
        return "current" if current?
        return "updating" if offered_recently?

        rollout = LinkRollout.current
        return "waiting" if rollout.nil?

        rollout.includes?(self) ? "updating" : (rollout.phase == "held" ? "held" : "waiting")
      end

      def noted_update!
        said = machine["update_result"]
        offered = details.to_h["offered"].to_h
        arrived = offered["sha256"].present? && offered["sha256"] == machine["sha256"] && offered["back"] != true

        if arrived
          merge_details!("updated" => { "at" => Time.current.utc.iso8601, "version" => machine["version"], "count" => updates_done + 1 })
          AuditEvent.record(channel: "link", action: "link_updated", status: "ok", told: "#{key} updated xixo link to #{machine['version']}",
                            arguments: { "key" => key, "version" => machine["version"] })
        end

        unmerge_details!("offered") if arrived || offered["back"] == true && offered["sha256"] == machine["sha256"]

        return if said.nil? || said["ok"] || said["at"].blank? || said["at"] == last_rollback.to_h["at"]

        merge_details!("rollback" => said.slice("at", "version", "sha256", "error"))
        AuditEvent.record(channel: "link", action: "link_update_failed", status: "error",
                          told: "#{key} could not update xixo link to #{said['version']}: #{said['error']}",
                          arguments: { "key" => key, "version" => said["version"] })
      end

      private

        def offered_recently?
          at = Time.iso8601(details.to_h.dig("offered", "at").to_s)
          at > OFFER_LASTS.ago
        rescue ArgumentError
          false
        end

        def merge_details!(held)
          Resource.where(id: id).update_all([ "details = details || ?::jsonb", held.to_json ])
          details.merge!(held)
        end

        def unmerge_details!(name)
          Resource.where(id: id).update_all([ "details = details - ?", name ])
          details.delete(name)
        end

        def mac_reader_build
          Downloads.mac_reader_build if machine["os"] == "darwin"
        end

        def current_mac_reader?
          reader = mac_reader_build
          reader.nil? || machine["mac_reader"] == reader.sha256
        end
    end
  end
end
