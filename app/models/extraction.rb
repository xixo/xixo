class Extraction
  WITHIN = 30.minutes
  MOST_FILES = 64

  Received = Data.define(:role, :name, :mime, :at, :file)

  attr_reader :reference, :kind, :verb, :machine, :extractor, :steps, :dropped, :files

  def self.settings
    {
      "thumbnail" => Setting.read("thumbnail_size", subject: nil).to_i,
      "preview" => Setting.read("hires_size", subject: nil).to_i,
      "frames" => Setting.read("animation_frames", subject: nil).to_i,
      "share" => Setting.read("animation_frame_share", subject: nil).to_i,
      "transcribe" => Analyzer::Media.span
    }
  end

  def initialize(reference, kind:, mime:, verb: "extract", skip: [])
    @reference = reference
    @kind = kind.to_s
    @mime = mime
    @verb = verb
    @skip = Array(skip)
    @files = []
  end

  def call
    @machine, source = route
    source ||= uploaded

    machine.exchanged(verb, asked(source), within: WITHIN) { |answer| received(answer) }
    self
  rescue Resource::Offline => e
    close!
    raise waiting(e.message, machine: source.is_a?(Hash) && source["folder"] ? machine : nil)
  rescue Resource::Machine::Refusal => e
    close!
    raise Analyzer::Failed, e.message
  rescue StandardError
    close!
    raise
  ensure
    machine.forget(source["upload"]) if machine && source.is_a?(Hash) && source["upload"]
  end

  def close!
    files.each { |held| held.file.close! }
    @files = []
  end

  def filename
    reference.filename
  end

  private

    def route
      folder = reference.try(:resource)
      return on_machine(folder) if folder.is_a?(Resource::Filesystem)

      pooled
    end

    def on_machine(folder)
      machine = folder.machine
      raise Analyzer::Failed, "#{folder.key} is reached through no machine, so nothing can read #{filename}" if machine.nil?
      raise waiting("#{machine.key}, where #{filename} lives, is not connected", machine: machine) unless machine.connected?
      raise Analyzer::Failed, "#{machine.key} no longer shares #{folder.folder}" unless machine.offered_folders.include?(folder.folder)
      return [ machine, { "folder" => folder.folder, "path" => reference.locator.to_h["path"].to_s } ] if reads?(machine)
      return pooled if machine.lends?

      raise waiting("#{machine.key} lacks #{wanted} and lends none of its files, so only it can read #{filename}",
                    machine: machine)
    end

    def pooled
      pool = Resource::Machine.pool.select { |machine| reads?(machine) }
      raise waiting("no connected machine that reads for others has #{wanted} to read #{filename}") if pool.empty?

      [ chosen(pool), nil ]
    end

    def chosen(pool)
      busy = LinkExchange.busy(pool.filter_map(&:id))

      pool.min_by { |machine| [ machine.local? ? 0 : 1, busy.fetch(machine.id, 0), machine.id.to_i ] }
    end

    def waiting(message, machine: nil)
      Analyzer::Waiting.new(message, kind: verb == "derive" ? nil : kind, machine: machine)
    end

    def wanted
      verb == "derive" ? "an extractor" : "the #{kind} extractor"
    end

    def reads?(machine)
      verb == "derive" ? machine.extractors.any? : machine.extracts?(kind)
    end

    def uploaded
      io = reference.download
      machine.upload(io)
    ensure
      io.respond_to?(:close!) ? io.close! : io&.close
    end

    def asked(source)
      {
        "source" => source.slice("upload", "folder", "path"),
        "size" => source["size"],
        "mime" => @mime.to_s,
        "filename" => filename.to_s,
        "skip" => @skip.presence,
        "settings" => self.class.settings
      }.compact
    end

    def received(answer)
      result = answer.result
      raise Analyzer::Failed, "#{machine.key} answered #{verb} with something that is not an extraction" unless result.is_a?(Hash)

      @extractor = result["extractor"].to_s.first(40).presence
      noted(result)
      @steps = result["steps"].is_a?(Hash) ? result["steps"] : {}
      @dropped = said(result["dropped"])
      answer.files.first(MOST_FILES).each { |entry| @files << kept(answer, entry) }
    end

    def kept(answer, entry)
      Received.new(
        role: entry["role"].to_s,
        name: File.basename(entry["name"].to_s.scrub.gsub(/[[:cntrl:]]/, "")).first(255),
        mime: entry["mime"].to_s.first(255),
        at: entry["at"].is_a?(Numeric) ? entry["at"].to_f : nil,
        file: answer.file(entry)
      )
    end

    def noted(result)
      return if result["sha256"].blank? || !reference.respond_to?(:fingerprinted!) || reference.digest.present?

      reference.fingerprinted!(Fingerprint.reported(result))
    end

    def said(dropped)
      return {} unless dropped.is_a?(Hash)

      dropped.first(32).to_h { |what, told| [ what.to_s.first(40), told.to_s.first(500) ] }
    end
end
