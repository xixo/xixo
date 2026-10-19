class Resource
  class Machine
    module Description
      KINDS = %w[laptop desktop all-in-one server].freeze
      MAKERS = %w[NVIDIA AMD Intel Apple].freeze
      MOST_ADDRESSES = 8
      MOST_DISKS = 16
      MOST_GPUS = 8
      MOST_CPUS = 4096
      MOST_BYTES = 2**62

      module_function

      def from(said, folders)
        said = said.is_a?(Hash) ? said.to_h.stringify_keys : {}

        {
          "user" => Hello.text(said["user"])&.first(64),
          "system" => Hello.text(said["system"])&.first(80),
          "model" => Hello.text(said["model"])&.first(80),
          "kind" => (said["kind"].to_s if KINDS.include?(said["kind"].to_s)),
          "battery" => said["battery"] == true,
          "version" => Hello.text(said["version"])&.first(32),
          "cpus" => count(said["cpus"], MOST_CPUS),
          "memory" => count(said["memory"], MOST_BYTES),
          "gpus" => gpus(said["gpus"]),
          "disks" => disks(said["disks"], folders),
          "addresses" => Hello.listed(said["addresses"]).first(MOST_ADDRESSES * 4)
                              .filter_map { |address| Hello.address(address) }.uniq.first(MOST_ADDRESSES),
          "readers" => Hello.extractors(said["readers"]),
          "services" => Hello.services(said["services"])
        }.compact
      end

      def gpus(said)
        Hello.listed(said).first(MOST_GPUS).filter_map do |gpu|
          next unless gpu.is_a?(Hash)

          gpu = gpu.to_h.stringify_keys
          maker = Hello.text(gpu["maker"])&.first(32)
          next unless MAKERS.include?(maker)

          { "maker" => maker, "model" => Hello.text(gpu["model"])&.first(80).to_s,
            "memory" => count(gpu["memory"], MOST_BYTES).to_i, "driver" => Hello.text(gpu["driver"])&.first(80).to_s }
        end
      end

      def remembered(now, before)
        Array(now).map do |gpu|
          next gpu if gpu["memory"].to_i.positive?

          known = Array(before).find { |held| held["maker"] == gpu["maker"] && held["model"] == gpu["model"] && held["memory"].to_i.positive? }
          known ? gpu.merge("memory" => known["memory"]) : gpu
        end
      end

      def disks(said, folders)
        Hello.listed(said).first(MOST_DISKS).filter_map do |disk|
          next unless disk.is_a?(Hash)

          disk = disk.to_h.stringify_keys
          path = Hello.folder(disk["path"])
          next unless path && (path == "/" || folders.include?(path))

          total = count(disk["total"], MOST_BYTES)
          free = count(disk["free"], MOST_BYTES)
          { "path" => path, "total" => total, "free" => [ free, total ].min } if total && free
        end.uniq { |disk| disk["path"] }
      end

      def count(value, most)
        value if value.is_a?(Integer) && value.between?(0, most)
      end
    end
  end
end
