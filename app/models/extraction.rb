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
    raise Analyzer::Waiting, e.message
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

      beside_the_server
    end

    def beside_the_server
      local = Resource::Machine.local
      raise Analyzer::Waiting, "xixo link beside the server is not connected to read #{filename}" unless local&.connected?
      unless reads?(local)
        raise Analyzer::Failed, "xixo link beside the server has no #{kind} extractor, so it cannot read #{filename}"
      end

      [ local, nil ]
    end

    def on_machine(folder)
      machine = folder.machine
      raise Analyzer::Waiting, "the machine that shares #{filename} is not connected" unless machine&.connected?
      raise Analyzer::Failed, "#{machine.key} no longer shares #{folder.folder}" unless machine.offered_folders.include?(folder.folder)
      return [ machine, { "folder" => folder.folder, "path" => reference.locator.to_h["path"].to_s } ] if reads?(machine)
      return beside_the_server if machine.lends? && !machine.local?
      raise Analyzer::Failed, "xixo link beside the server has no #{kind} extractor, so it cannot read #{filename}" if machine.local?

      raise Analyzer::Failed,
            "#{machine.key} has no #{kind} extractor, and a file on a machine is read only by its own xixo link " \
            "unless the machine's \"Send files this machine can't read to the server\" setting is on"
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
