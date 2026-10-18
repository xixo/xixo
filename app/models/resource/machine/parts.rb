class Resource
  class Machine
    module Parts
      MODELS = "models".freeze
      NAMES = [ MODELS ].freeze
      STATES = %w[missing fetching starting running failed stopped].freeze
      PORT = 11440
      CONTEXT = 32_768
      KEEP_ALIVE = "30m".freeze
      MOST_PULLS = 16
      LEAST_GPU_MEMORY = 4.gigabytes
      LEAST_APPLE_MEMORY = 16.gigabytes
      TIERS = [
        [ 24.gigabytes, { "default" => "qwen3:14b", "vision" => "gemma3:12b", "embedding" => "nomic-embed-text" } ],
        [ 6.gigabytes, { "default" => "qwen3:8b", "vision" => "gemma3:4b", "embedding" => "nomic-embed-text" } ],
        [ 0, { "default" => "qwen3:4b", "vision" => "gemma3:4b", "embedding" => "nomic-embed-text" } ]
      ].freeze

      module_function

      def gpu_for_models(about)
        Array(about["gpus"]).find { |gpu| usable?(gpu) }
      end

      def usable?(gpu)
        case gpu["maker"]
        when "NVIDIA" then gpu["driver"].present? && gpu["driver"] != "nouveau" && gpu["memory"].to_i >= LEAST_GPU_MEMORY
        when "Apple" then gpu["memory"].to_i >= LEAST_APPLE_MEMORY
        else false
        end
      end

      def roles_for(gpu)
        TIERS.find { |least, _| gpu["memory"].to_i >= least }.last
      end

      def settings_for(gpu)
        { "port" => PORT, "models" => roles_for(gpu).values.uniq, "context" => CONTEXT, "keep_alive" => KEEP_ALIVE }
      end

      def statuses(said)
        Hello.listed(said).first(NAMES.size * 2).filter_map do |held|
          next unless held.is_a?(Hash) && NAMES.include?(held["name"]) && STATES.include?(held["state"])

          port = held["port"]
          {
            "name" => held["name"],
            "version" => Hello.text(held["version"])&.first(32),
            "state" => held["state"],
            "port" => (port if port.is_a?(Integer) && port.between?(1, 65_535)),
            "warning" => Hello.text(held["warning"])&.first(MOST_WARNING),
            "pulls" => pulls(held["pulls"])
          }.compact
        end.uniq { |held| held["name"] }
      end

      def pulls(said)
        Hello.listed(said).first(MOST_PULLS).filter_map do |pull|
          next unless pull.is_a?(Hash) && pull["model"].is_a?(String)

          { "model" => pull["model"].scrub.first(200), "done" => Health.count(pull["done"]).to_i,
            "total" => Health.count(pull["total"]).to_i, "ready" => pull["ready"] == true,
            "error" => Hello.text(pull["error"])&.first(MOST_WARNING) }.compact
        end
      end
    end
  end
end
