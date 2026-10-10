module Analyzer
  class Media < Base
    SAMPLE_RATE = "16000".freeze
    CHANNELS = "1".freeze
    DEFAULT_SPAN = 3600
    STREAMS = 8
    TAGS = %w[title artist album_artist album date genre composer comment].freeze
    SILENCE = "-50dB".freeze
    SHORTEST_SILENCE = 0.5
    SILENCES = 20
    SILENT_FLOOR = -70.0
    DYNAMICS = [ [ 3, "steady" ], [ 10, "moderate" ], [ Float::INFINITY, "wide" ] ].freeze
    BRIGHTNESS = [ [ 500, "dark" ], [ 2000, "middle" ], [ Float::INFINITY, "bright" ] ].freeze
    TEXTURE = [ [ 0.05, "tonal" ], [ 0.5, "mixed" ], [ Float::INFINITY, "noisy" ] ].freeze
    WRITTEN_AS = "a timestamp on each line".freeze
    STILLS = %w[mjpeg png gif bmp].freeze
    FRAMES = 8
    SCENE_SECONDS = 8
    FRAME_WIDTH = 768

    SCENE = <<~TEXT.freeze
      This is a frame from a video, %<at>s into it. Say in one or two sentences what it shows: the
      people, objects, colours, and setting, and any text in it exactly as written. Say only what you
      can see.

      Return ONLY valid JSON: {"caption": "..."}
    TEXT

    def self.handles?(feed)
      MimeType.audio?(feed.mime) || MimeType.video?(feed.mime)
    end

    def self.span
      ENV.fetch("XIXO_TRANSCRIBE_SECONDS", DEFAULT_SPAN).to_i
    end

    def analyze
      with_tempfile do |path|
        step(:probe, digest: TAGS.join(",")) { probe(path) }
        attempt { step(:signal) { signal(path) } } if audio?

        heard(path)

        seen(path)
      end
    end

    def heard(path)
      listening = Resource.for_declared_role(:transcription)

      if listening.nil?
        analysis&.log_skip(log_context, "transcript", "no model backend serves transcription")
        return
      end

      digest = [ WRITTEN_AS, listening.key, listening.model_for(:transcription) ].join("/")
      attempt { step(:transcript, digest: digest) { transcribe(path, listening) } }
    end

    def seen(path)
      seeing = Resource.for_role(:vision)
      return if seeing.nil? || !video? || !duration.positive?

      digest = [ FRAMES, SCENE_SECONDS, seeing.key, seeing.model_for(:vision) ].join("/")
      attempt { step(:scenes, digest: digest) { scenes(path, seeing) } }
    end

    def file_facts
      [ super, duration_said, streams_said, tags_said, sound_said ].compact_blank.join("\n")
    end

    def summary_body
      seen = Array(step_result(:scenes)).map { |scene| "[#{scene['at']}] Seen: #{scene['caption']}" }
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

      def probe(path)
        parsed = JSON.parse(
          run_command("ffprobe", "-v", "error", "-print_format", "json",
                      "-show_format", "-show_streams", path)
        )

        tags = parsed.dig("format", "tags").to_h.transform_keys(&:downcase)

        {
          "format" => parsed.dig("format", "format_name"),
          "duration" => parsed.dig("format", "duration")&.to_f&.round(2),
          "bit_rate" => parsed.dig("format", "bit_rate")&.to_i,
          "streams" => Array(parsed["streams"]).first(STREAMS).map { |stream| described(stream) }
        }.merge(TAGS.to_h { |tag| [ tag, tags[tag].to_s.squish.truncate(200).presence ] }).compact
      rescue JSON::ParserError
        raise Analyzer::Failed, "ffprobe did not describe #{reference.filename}"
      end

      def described(stream)
        {
          "type" => stream["codec_type"],
          "codec" => stream["codec_name"],
          "width" => stream["width"],
          "height" => stream["height"],
          "channels" => stream["channels"],
          "sample_rate" => stream["sample_rate"]&.to_i,
          "language" => stream.dig("tags", "language")
        }.compact
      end

      def transcribe(path, listening)
        raise Analyzer::Failed, "#{reference.filename} carries no audio" unless audio?

        Dir.mktmpdir do |dir|
          heard = File.join(dir, "heard.wav")

          run_command("ffmpeg", "-v", "error", "-y", "-i", path, "-vn",
                      "-t", self.class.span.to_s, "-ac", CHANNELS, "-ar", SAMPLE_RATE,
                      "-f", "wav", heard)

          listening.transcribe(File.binread(heard)).truncate(MAX_TEXT)
        rescue Resource::Unusable, Resource::Failed => e
          raise Analyzer::Failed, e.message
        end
      end

      def signal(path)
        Dir.mktmpdir do |dir|
          spectral = File.join(dir, "spectral.txt")
          graph = [
            "ebur128=peak=true:framelog=quiet",
            "silencedetect=noise=#{SILENCE}:d=#{SHORTEST_SILENCE}",
            "aformat=channel_layouts=mono",
            "aspectralstats=measure=centroid+flatness",
            "ametadata=mode=print:file=#{spectral}"
          ].join(",")

          _out, err, status = begin
            Command.capture("ffmpeg", "-hide_banner", "-nostats", "-i", path, "-vn",
                            "-t", self.class.span.to_s, "-af", graph, "-f", "null", "-")
          rescue Command::Stopped => e
            raise Analyzer::Failed, e.message
          end
          raise Analyzer::Failed, "ffmpeg could not measure #{reference.filename}" unless status.success?

          measured(err, File.exist?(spectral) ? File.foreach(spectral).to_a : [])
        end
      end

      def measured(said, frames)
        heard = [ duration, self.class.span ].select(&:positive?).min.to_f
        loudness = number(said[/I:\s+(-?[\d.]+) LUFS/, 1])
        silences = silences(said, heard)
        centroids = series(frames, "centroid")
        flatness = series(frames, "flatness")

        found = {
          "loudness" => loudness,
          "range" => number(said[/LRA:\s+([\d.]+) LU/, 1]),
          "peak" => number(said[/Peak:\s+(-?[\d.]+) dBFS/, 1]),
          "silent" => silences.sum { |from, to| to - from }.round(2),
          "silences" => silences.first(SILENCES),
          "centroid" => middle(centroids)&.round,
          "flatness" => middle(flatness)&.round(4)
        }

        found.merge("silent_throughout" => silent_throughout?(found, heard)).compact
      end

      def silences(said, heard)
        starts = said.scan(/silence_start: (-?[\d.]+)/).flatten.map(&:to_f)
        ends = said.scan(/silence_end: ([\d.]+)/).flatten.map(&:to_f)

        starts.each_with_index.map do |from, index|
          [ [ from, 0.0 ].max.round(2), (ends[index] || heard).round(2) ]
        end
      end

      def silent_throughout?(found, heard)
        return true if found["loudness"].nil? || found["loudness"] <= SILENT_FLOOR

        heard.positive? && found["silent"] >= heard * 0.95
      end

      def series(frames, measure)
        frames.filter_map do |line|
          value = line[/\.#{measure}=(\S+)/, 1]
          value && Float(value, exception: false)&.then { |number| number.finite? ? number : nil }
        end
      end

      def middle(values)
        values.empty? ? nil : values.sort[values.size / 2]
      end

      def number(value)
        value && Float(value, exception: false)
      end

      def scenes(path, seeing)
        count = (duration / SCENE_SECONDS).floor.clamp(1, FRAMES)

        Dir.mktmpdir do |dir|
          Array.new(count) do |index|
            at = duration * (index + 0.5) / count
            moment = stamped(at)
            frame = File.join(dir, "#{index}.jpg")
            run_command("ffmpeg", "-v", "error", "-y", "-ss", at.round(2).to_s, "-i", path,
                        "-frames:v", "1", "-vf", "scale=#{FRAME_WIDTH}:-2", frame)

            said = seeing.summarize(format(SCENE, at: moment), role: :vision, analysis: analysis,
                                    images: [ File.binread(frame) ])["caption"].to_s.squish
            { "at" => moment, "caption" => said } if said.present?
          end.compact
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
        Array(step_result(:probe).to_h["streams"])
      end

      def duration
        step_result(:probe).to_h["duration"].to_f
      end

      def duration_said
        return nil unless duration.positive?

        "Length: #{ActiveSupport::Duration.build(duration.round).inspect}"
      end

      def tags_said
        held = step_result(:probe).to_h
        named = TAGS.filter_map { |tag| "#{tag.tr('_', ' ').capitalize}: #{held[tag]}" if held[tag] }

        named.join("\n").presence
      end

      def sound_said
        found = step_result(:signal).to_h
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
          ("Silent for #{found['silent']} s in #{found['silences'].size} spans." if found["silent"].to_f.positive?)
        ].compact.join("\n")
      end

      def banded(value, bands)
        return nil if value.nil?

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
