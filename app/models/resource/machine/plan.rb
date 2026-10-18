class Resource
  class Machine
    module Plan
      KEYS = %w[catalog extract models].freeze
      SERVED_AS = { "ollama" => "Ollama", "lmstudio" => "LM Studio" }.freeze
      USABLE_GPUS = %w[NVIDIA Apple].freeze

      Line = Data.define(:key, :says, :why, :on, :possible) do
        def to_h = { "key" => key, "says" => says, "why" => why, "on" => on, "possible" => possible }
      end

      module_function

      def lines(about, folders:, writable:, off: [])
        about = about.to_h
        folders = Array(folders)
        writable = Array(writable) & folders

        [ catalog(folders, writable), extract(about), models(about) ].map do |line|
          line.with(on: line.possible && !Array(off).include?(line.key))
        end
      end

      def catalog(folders, writable)
        if folders.empty?
          return Line.new(key: "catalog", says: "Catalog no folders.", on: false, possible: false,
                          why: "It shares none. Run the link-up command on it again with the folders to share.")
        end

        read = (folders - writable).map { |path| File.basename(path) }
        said = []
        said << "Catalog #{read.to_sentence}." if read.any?
        said << "Read and write #{writable.map { |path| File.basename(path) }.to_sentence}." if writable.any?

        Line.new(key: "catalog", says: said.join(" "), why: nil, on: true, possible: true)
      end

      def extract(about)
        readers = Array(about["readers"]) & EXTRACTORS
        if readers.empty?
          return Line.new(key: "extract", says: "Extract no text.", on: false, possible: false,
                          why: "None of the readers are installed on it, so other machines read its files.")
        end

        Line.new(key: "extract", says: "Extract text from documents, and from files other machines lend it.",
                 why: "It reads #{READ_AS.values_at(*readers).compact.to_sentence}.", on: true, possible: true)
      end

      def models(about)
        found = found_server(about)
        if found
          return Line.new(key: "models", says: "Use the #{SERVED_AS[found['kind']]} already running on it.",
                          why: "It answers on port #{found['port']}.", on: true, possible: true)
        end

        gpu = Parts.gpu_for_models(about)
        if gpu
          roles = Parts.roles_for(gpu)
          return Line.new(key: "models", says: "Run models on its #{named(gpu)}, #{sized(gpu)}.",
                          why: "xixo installs Ollama on it and pulls #{roles.values.uniq.to_sentence}.", on: true, possible: true)
        end

        Line.new(key: "models", says: "Run no models.", why: without_models(about), on: false, possible: false)
      end

      def found_server(about)
        Array(about["services"]).find { |service| SERVED_AS.key?(service["kind"]) }
      end

      def installs_models?(about)
        found_server(about).nil? && Parts.gpu_for_models(about).present?
      end

      def named(gpu)
        gpu["model"].presence || "#{gpu['maker']} GPU"
      end

      def sized(gpu)
        ActiveSupport::NumberHelper.number_to_human_size(gpu["memory"].to_i)
      end

      def without_models(about)
        gpu = Array(about["gpus"]).find { |held| USABLE_GPUS.include?(held["maker"]) }
        return "It has no GPU xixo can run models on, so models run on another machine." if gpu.nil?

        case
        when gpu["maker"] == "NVIDIA" && gpu["driver"].blank?
          "Its #{named(gpu)} has no driver, so models run on another machine."
        when gpu["maker"] == "NVIDIA" && gpu["driver"] == "nouveau"
          "Its #{named(gpu)} runs the nouveau driver, which no model server uses, so models run on another machine."
        else
          "Its #{named(gpu)}, with #{sized(gpu)}, is too small for a model server, so models run on another machine."
        end
      end
    end
  end
end
