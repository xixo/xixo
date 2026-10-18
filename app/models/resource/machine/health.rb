class Resource
  class Machine
    module Health
      module_function

      def from(said)
        said = said.to_h

        {
          "uptime" => number(said["uptime"]),
          "load" => Array(said["load"]).first(3).map { |held| number(held) },
          "memory" => memory(said["memory"]),
          "disks" => Array(said["disks"]).first(MOST_DISKS).filter_map { |disk| disk(disk) },
          "parts" => Parts.statuses(said["parts"])
        }
      end

      def number(value)
        value.is_a?(Numeric) && value.finite? && value >= 0 ? value : nil
      end

      def count(value)
        value.is_a?(Integer) && value >= 0 ? value : nil
      end

      def memory(value)
        held = value.is_a?(Hash) ? value : {}

        { "total" => count(held["total"]), "available" => count(held["available"]) }
      end

      def disk(value)
        return unless value.is_a?(Hash)

        path = Hello.folder(value["path"])
        path && { "path" => path, "total" => count(value["total"]), "free" => count(value["free"]) }
      end
    end
  end
end
