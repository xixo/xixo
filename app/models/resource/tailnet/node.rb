class Resource
  class Tailnet
    module Node
      HOST = /\A[a-z0-9][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*\z/

      module_function

      def from(peer, covers)
        return unless peer.is_a?(Hash)

        addresses = Array(peer["TailscaleIPs"]).filter_map { |held| covered(held, covers) }
        host_name = normalized(peer["HostName"])
        dns_name = normalized(peer["DNSName"])
        return if addresses.empty? && host_name.nil? && dns_name.nil?

        {
          "host_name" => host_name || dns_name&.split(".")&.first,
          "dns_name" => dns_name,
          "addresses" => addresses.sort_by { |address| address.include?(":") ? 1 : 0 },
          "online" => peer["Online"] == true,
          "last_seen" => seen(peer["LastSeen"])
        }
      end

      def normalized(host)
        held = host.to_s.strip.downcase.delete_prefix("[").delete_suffix("]").chomp(".")
        return if held.empty? || held.bytesize > 253

        address(held) || (held if held.match?(HOST))
      end

      def answers_to?(node, named)
        return true if node["addresses"].include?(named)
        return true if [ node["host_name"], node["dns_name"] ].include?(named)

        node["dns_name"].present? && node["dns_name"].split(".").first == named
      end

      def address(held)
        IPAddr.new(held).to_s
      rescue IPAddr::Error
        nil
      end

      def covered(held, covers)
        named = address(held.to_s)
        named if named && covers.any? { |range| range.include?(IPAddr.new(named)) }
      end

      def seen(held)
        time = Time.iso8601(held.to_s)
        time.utc.iso8601 if time > Tailnet::NEVER
      rescue ArgumentError
        nil
      end
    end
  end
end
