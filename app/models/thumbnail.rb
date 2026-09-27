require "open3"

class Thumbnail
  class Unavailable < StandardError; end

  ROLES = { Reference::THUMBNAIL => "thumbnail_size", Reference::PREVIEW => "hires_size" }.freeze
  PDF = "application/pdf".freeze
  POSTER_AT = "00:00:01".freeze
  CONTENT_TYPE = "image/jpeg"
  WAVE = "0xc9a86a".freeze
  GROUND = "0x1b2024".freeze
  WAVE_SECONDS = 3600
  WAVE_MIN_WIDTH = 1000
  WAVE_MAX_WIDTH = 2000

  def self.for(reference, role: Reference::THUMBNAIL)
    new(reference, role).bytes
  end

  def self.width(role)
    Setting.read(ROLES.fetch(role), subject: nil).to_i
  end

  def self.widths
    ROLES.keys.to_h { |role| [ role, width(role) ] }
  end

  def self.available_for?(mime)
    MimeType.image?(mime) || MimeType.video?(mime) || MimeType.audio?(mime) ||
      [ PDF, MimeType::PAGE ].include?(mime.to_s)
  end

  def self.stored!(feed, source)
    store = Resource.internal!(:derived)

    ROLES.keys.to_h do |role|
      key = "#{feed.id}/#{role}.jpg"
      locator = store.upload(key, self.for(source, role: role))

      Reference.record!(feed: feed, resource: store, locator: locator, locator_key: key,
                        role: role, mime: CONTENT_TYPE)

      [ role, key ]
    end
  end

  def initialize(reference, role)
    @reference = reference
    @role = role
    @width = ROLES.key?(role) ? self.class.width(role) : raise(Unavailable, "no derived image called #{role}")

    raise Unavailable, "nothing to render for a #{reference.mime}" unless
      self.class.available_for?(reference.mime)
  end

  def bytes
    render
  end

  private

    attr_reader :reference, :role, :width

    def hires?
      role == Reference::PREVIEW
    end

    def bounds
      hires? ? "#{width}x#{width}>" : "#{width}x>"
    end

    def render
      source do |path|
        Dir.mktmpdir do |dir|
          case reference.mime
          when MimeType::PAGE then from_page(path, dir)
          when PDF then from_pdf(path, dir)
          else
            if MimeType.video?(reference.mime) then from_video(path, dir)
            elsif MimeType.audio?(reference.mime) then from_audio(path, dir)
            else from_image(path, dir)
            end
          end
        end
      end
    end

    def from_image(path, dir)
      viewable(path) do |ready|
        out = File.join(dir, "out.jpg")
        run("vipsthumbnail", ready, "--size", bounds, "-o", "#{out}[Q=80]")
        File.binread(out)
      end
    end

    # A full-page capture is a column metres long, and scaled to a tile it is a
    # thread with nothing legible in it. Tiles take the top of the page square;
    # the preview, which the vision analyzer reads, keeps the whole column.
    def from_page(path, dir)
      out = File.join(dir, "out.jpg")
      crop = hires? ? [] : [ "--smartcrop", "low" ]
      geometry = hires? ? "#{width}x>" : "#{width}x#{width}"

      run("vipsthumbnail", path, "--size", geometry, *crop, "-o", "#{out}[Q=80]")
      File.binread(out)
    end

    def viewable(path, &block)
      return yield(path) unless MimeType.raw?(reference.locator_key)

      Raw.preview(path, &block)
    rescue Raw::Unreadable => e
      raise Unavailable, e.message
    end

    def from_video(path, dir)
      frame = File.join(dir, "frame.png")
      out = File.join(dir, "out.jpg")

      attempt("ffmpeg", "-v", "error", "-y", "-ss", POSTER_AT, "-i", path, "-frames:v", "1", frame)
      run("ffmpeg", "-v", "error", "-y", "-i", path, "-frames:v", "1", frame) unless File.size?(frame)

      raise Unavailable, "ffmpeg rendered no frame of #{reference.filename}" unless File.size?(frame)

      run("vipsthumbnail", frame, "--size", bounds, "-o", "#{out}[Q=80]")
      File.binread(out)
    end

    def from_audio(path, dir)
      out = File.join(dir, "out.jpg")
      wide = wave_width(path)
      shape = "#{wide}x#{wide / 3}"
      graph = "[0:a]aformat=channel_layouts=mono,showwavespic=s=#{shape}:scale=sqrt:colors=#{WAVE}[wave];" \
              "color=c=#{GROUND}:s=#{shape}[ground];[ground][wave]overlay=format=auto"

      run("ffmpeg", "-v", "error", "-y", "-t", WAVE_SECONDS.to_s, "-i", path,
          "-filter_complex", graph, "-frames:v", "1", "-q:v", "3", out)

      raise Unavailable, "ffmpeg drew no waveform of #{reference.filename}" unless File.size?(out)

      File.binread(out)
    end

    def wave_width(path)
      seconds = capture("ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", path).to_f
      rendered = seconds.clamp(0, WAVE_SECONDS)
      spread = WAVE_MAX_WIDTH - WAVE_MIN_WIDTH

      (WAVE_MIN_WIDTH + (rendered / WAVE_SECONDS) * spread).round.clamp(WAVE_MIN_WIDTH, WAVE_MAX_WIDTH)
    end

    def attempt(*args)
      run(*args)
    rescue Unavailable
      false
    end

    def from_pdf(path, dir)
      prefix = File.join(dir, "page")
      scale = hires? ? [ "-scale-to", width.to_s ] : [ "-scale-to-x", width.to_s, "-scale-to-y", "-1" ]
      run("pdftoppm", "-jpeg", "-r", "72", "-f", "1", "-l", "1", *scale, path, prefix)

      rendered = Dir["#{prefix}*.jpg"].first
      raise Unavailable, "pdftoppm rendered no page" if rendered.nil?

      File.binread(rendered)
    end

    # A page's locator key is the address it was taken from, and the tail of a URL
    # says nothing about the bytes — the capture is always a PNG.
    def suffix
      return ".png" if reference.mime == MimeType::PAGE

      File.extname(reference.locator_key.to_s)
    end

    def source
      Tempfile.create([ "thumb", suffix ], binmode: true) do |file|
        IO.copy_stream(reference.download, file)
        file.flush
        yield file.path
      end
    end

    def run(*args)
      _out, err, status = Open3.capture3(*args)
      raise Unavailable, "#{args.first}: #{err.truncate(200)}" unless status.success?

      true
    end

    def capture(*args)
      out, err, status = Open3.capture3(*args)
      raise Unavailable, "#{args.first}: #{err.truncate(200)}" unless status.success?

      out
    end
end
