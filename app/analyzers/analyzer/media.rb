module Analyzer
  class Media < Base
    DEFAULT_SPAN = 3600
    TAGS = %w[title artist album_artist album date genre composer comment].freeze
    DYNAMICS = [ [ 3, "steady" ], [ 10, "moderate" ], [ Float::INFINITY, "wide" ] ].freeze
    BRIGHTNESS = [ [ 500, "dark" ], [ 2000, "middle" ], [ Float::INFINITY, "bright" ] ].freeze
    TEXTURE = [ [ 0.05, "tonal" ], [ 0.5, "mixed" ], [ Float::INFINITY, "noisy" ] ].freeze
    WRITTEN_AS = "a timestamp on each line".freeze
    STILLS = %w[mjpeg png gif bmp].freeze

    SCENE = <<~TEXT.freeze
      This is a frame from a video, %<at>s into it. Say in one or two sentences what it shows: the
      people, objects, colours, and setting, and any text in it exactly as written. Say only what you
      can see.

      Return ONLY valid JSON: {"caption": "..."}
    TEXT

    CAPTION = { type: "object", properties: { caption: { type: "string" } }, required: %w[caption] }.freeze

    def self.handles?(feed)
      MimeType.audio?(feed.mime) || MimeType.video?(feed.mime)
    end

    def self.span
      ENV.fetch("XIXO_TRANSCRIBE_SECONDS", DEFAULT_SPAN).to_i
    end

    def analyze
      heard
      seen
    end

    def wants_files?
      listening = Resource.for_declared_role(:transcription)
      return false if listening.nil? || !audio?

      held = analysis&.step("transcript").to_h
      !held.key?("result") || held["digest"] != transcript_digest(listening)
    end

    def skipped_work
      Resource.for_declared_role(:transcription).nil? ? [ "transcript" ] : []
    end

    def heard
      listening = Resource.for_declared_role(:transcription)

      if listening.nil?
        analysis&.log_skip(log_context, "transcript", "no model backend serves transcription")
        return
      end

      attempt { step(:transcript, digest: transcript_digest(listening)) { transcribe(listening) } }
    end

    def seen
      seeing = Resource.for_role(:vision)
      shown = frames_seen
      return if seeing.nil? || !video? || shown.empty?

      digest = [ shown.size, seeing.key, seeing.model_for(:vision) ].join("/")
      attempt { step(:scenes, digest: digest) { scenes(shown, seeing) } }
    end

    def file_facts
      [ super, duration_said, streams_said, tags_said, sound_said ].compact_blank.join("\n")
    end

    def summary_body
      seen = step_list(:scenes).select { |scene| scene.is_a?(Hash) }.map { |scene| "[#{scene['at']}] Seen: #{scene['caption']}" }
      fenced([ step_result(:transcript).to_s.strip, *seen ].compact_blank.join("\n"))
    end

    SAYS = <<~SAYS.strip.freeze
      two or three sentences on what is said and who says it. Name the people,
          places, products and dates spoken rather than their category. Where nothing
          was transcribed, say what the recording is from its name, length, tags and
          how it sounds, and say plainly that no words were heard.
    SAYS

    def summary_noun
      "recording"
    end

    def summary_says
      SAYS
    end

    private

      def transcript_digest(listening)
        [ WRITTEN_AS, listening.key, listening.model_for(:transcription) ].join("/")
      end

      def transcribe(listening)
        raise Analyzer::Failed, "#{reference.filename} carries no audio" unless audio?

        wav = received("audio").first
        raise Analyzer::Failed, "the machine sent no audio of #{reference.filename} to transcribe" if wav.nil?

        wav.file.rewind
        capped(listening.transcribe(wav.file.read))
      rescue Resource::Unusable, Resource::Failed => e
        raise Analyzer::Failed, e.message
      end

      def scenes(shown, seeing)
        shown.filter_map do |frame|
          moment = stamped(frame.locator.to_h["at"].to_f)
          said = seeing.summarize(format(SCENE, at: moment), role: :vision, analysis: analysis,
                                  images: [ frame.download.read ], schema: CAPTION)["caption"].to_s.squish
          { "at" => moment, "caption" => said } if said.present?
        end
      end

      def stamped(seconds)
        Time.at(seconds).utc.strftime("%H:%M:%S")
      end

      def video?
        streams.any? { |stream| stream["type"] == "video" && !STILLS.include?(stream["codec"]) }
      end

      def audio?
        streams.any? { |stream| stream["type"] == "audio" }
      end

      def streams
        Array(step_hash(:probe)["streams"]).select { |stream| stream.is_a?(Hash) }
      end

      def duration
        held = step_hash(:probe)["duration"]
        held.is_a?(Numeric) ? held.to_f : 0.0
      end

      def duration_said
        return nil unless duration.positive?

        "Length: #{ActiveSupport::Duration.build(duration.round).inspect}"
      end

      def tags_said
        held = step_hash(:probe)
        named = TAGS.filter_map { |tag| "#{tag.tr('_', ' ').capitalize}: #{held[tag]}" if held[tag] }

        named.join("\n").presence
      end

      def sound_said
        found = step_hash(:signal)
        return nil if found.empty?
        return "Sound: silent throughout." if found["silent_throughout"]

        described = {
          "dynamics" => banded(found["range"], DYNAMICS),
          "brightness" => banded(found["centroid"], BRIGHTNESS),
          "texture" => banded(found["flatness"], TEXTURE)
        }.compact.map { |measure, band| "#{band} #{measure}" }

        [
          ("Sound: #{described.join(', ')}." if described.any?),
          ("Loudness: #{found['loudness']} LUFS, peaking at #{found['peak']} dBFS." if found["loudness"]),
          ("Silent for #{found['silent']} s in #{Array(found['silences']).size} spans." if silent?(found["silent"]))
        ].compact.join("\n")
      end

      def silent?(seconds)
        seconds.is_a?(Numeric) && seconds.positive?
      end

      def banded(value, bands)
        return nil unless value.is_a?(Numeric)

        bands.find { |limit, _| value < limit }&.last
      end

      def streams_said
        described = streams.filter_map do |stream|
          case stream["type"]
          when "video" then "video #{stream['codec']} #{stream['width']}×#{stream['height']}"
          when "audio" then "audio #{stream['codec']} #{stream['channels']}ch"
          end
        end

        "Streams: #{described.join(', ')}" if described.any?
      end
  end
end
