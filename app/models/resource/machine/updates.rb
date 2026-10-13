class Resource
  class Machine
    module Updates
      def updates?
        details.to_h["updates"] != false
      end

      def updates_itself?
        !local? && Hello::UPDATES.include?(machine["updates"])
      end

      def release
        Downloads.version
      end

      def current?
        build = Downloads.build_for(machine["os"], machine["arch"])
        return nil if build.nil? || machine["version"].blank?
        return machine["version"] == release if machine["sha256"].blank?

        machine["sha256"] == build.sha256 && current_mac_reader?
      end

      def update_offer
        return unless updates? && updates_itself?

        build = Downloads.build_for(machine["os"], machine["arch"])
        version = release
        return if build.nil? || version.nil? || current?

        offer = { "version" => version, "sha256" => build.sha256, "downgrade" => Downloads.older?(version, machine["version"]) }
        reader = mac_reader_build
        offer["mac_reader"] = reader.sha256 if reader
        offer
      end

      def offer_update!
        offer = update_offer
        LinkChannel.broadcast_to(self, { "update" => offer }) if offer
        offer
      end

      def set_updates!(on)
        update!(details: details.to_h.merge("updates" => on == true))
        offer_update! if on
        announce!
      end

      private

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
