require "open3"

class Metadata
  class Unreadable < StandardError; end

  VERSION = "3".freeze
  SECONDS = 30
  TAGS = 200
  VALUE = 500
  LIST = 24

  QUIET = %w[ExifTool File System ICC_Profile MakerNotes JFIF APP14 Photoshop PrintIM ZIP JSON].freeze

  PLUMBING = %w[
    SourceFile ExifByteOrder ExifVersion FlashpixVersion ComponentsConfiguration
    XResolution YResolution ResolutionUnit YCbCrPositioning YCbCrSubSampling
    ThumbnailOffset ThumbnailLength ThumbnailImage PreviewImage PreviewImageStart
    PreviewImageLength JpgFromRaw JpgFromRawStart JpgFromRawLength OtherImage
    OtherImageStart OtherImageLength StripOffsets StripByteCounts RowsPerStrip
    PlanarConfiguration BitsPerSample SamplesPerPixel Compression EncodingProcess
    InteropIndex InteropVersion PDFVersion Linearized XMPToolkit DocumentID
    InstanceID OriginalDocumentID DerivedFromDocumentID DerivedFromInstanceID
    HistoryAction HistoryInstanceID HistoryWhen HistorySoftwareAgent HistoryChanged
    CFAPattern CFAPattern2 CFARepeatPatternDim ReferenceBlackWhite TIFF-EPStandardID
    SubfileType PhotometricInterpretation GPSVersionID SubSecTime SubSecTimeOriginal
    SubSecTimeDigitized SubSecCreateDate SubSecModifyDate SubSecDateTimeOriginal
    FocalLength35efl ScaleFactor35efl CircleOfConfusion HyperfocalDistance FOV
    DigitalZoomRatio RedBalance BlueBalance BlackLevel WhiteLevel
    MatrixStructure GraphicsMode OpColor HandlerType HandlerVendorID HandlerDescription
    MediaDataOffset MediaDataSize MediaHeaderVersion MovieHeaderVersion TrackHeaderVersion
    NextTrackID TrackID TrackLayer TrackVolume PreferredRate PreferredVolume PreviewTime
    PreviewDuration PosterTime SelectionTime SelectionDuration CurrentTime TimeScale
    MediaTimeScale BufferSize MinorVersion SourceImageWidth SourceImageHeight BitDepth
    AverageBitrate Emphasis CopyrightFlag OriginalMedia IntensityStereo MSStereo
    RevisionNumber TotalEditTime Template AppVersion Xmlns
  ].freeze

  UNSET = /\A(0000:00:00 00:00:00|0+ s)\z/

  def self.describes?(mime)
    !MimeType.text?(mime) && !mime.to_s.match?(%r{[/+](json|xml)\z})
  end

  def self.read(path)
    stdout, stderr, status = exiftool("-json", "-G0", "-fast", "-api", "LargeFileSupport=1", path)
    raise Unreadable, "exiftool failed: #{stderr.truncate(200)}" unless status.success? || stdout.present?

    tidy(JSON.parse(stdout).first.to_h)
  rescue JSON::ParserError => e
    raise Unreadable, "exiftool said something unreadable: #{e.message.truncate(200)}"
  rescue Errno::ENOENT
    raise Unreadable, "exiftool is not installed"
  end

  def self.exiftool(*args)
    Open3.popen3("exiftool", *args) do |stdin, stdout, stderr, waiter|
      stdin.close
      said = Thread.new { stdout.read }
      complained = Thread.new { stderr.read }

      unless waiter.join(SECONDS)
        Process.kill("KILL", waiter.pid)
        raise Unreadable, "exiftool took longer than #{SECONDS} seconds"
      end

      [ said.value, complained.value, waiter.value ]
    end
  end

  def self.tidy(said)
    held = {}

    said.each do |named, value|
      group, tag = named.include?(":") ? named.split(":", 2) : [ nil, named ]
      next if QUIET.include?(group) || PLUMBING.include?(tag) || held.key?(tag)

      shown = shown(value)
      held[tag] = shown unless shown.nil?
      break if held.size >= TAGS
    end

    held
  end

  def self.shown(value)
    case value
    when Array
      listed = value.filter_map { |each| shown(each) }.first(LIST)
      listed.join(", ").presence
    when Hash
      nil
    when Numeric, true, false
      value
    else
      text = value.to_s.scrub.strip
      return nil if text.empty? || text.start_with?("(Binary data") || text.match?(UNSET)

      text.truncate(VALUE)
    end
  end

  private_class_method :exiftool, :tidy, :shown
end
