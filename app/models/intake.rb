class Intake
  class Unusable < StandardError; end

  MAX_KEY = 900
  MAX_NAME = 180

  Landed = Data.define(:feed, :staged, :analysis, :duplicate) do
    def initialize(feed:, staged: nil, analysis: nil, duplicate: false) = super
  end

  class << self
    def write!(path:, body:, mime: nil, title: nil, source: nil, cause: "upload", unique: false)
      key = key_for(path)
      type = mime.presence || MimeType.for_filename(key)
      size = body.is_a?(String) ? body.bytesize : body.size

      unless Resource.placeable(type, size: size).exists?
        raise Unusable, "nowhere accepts a #{type} of #{size} bytes — attach storage on Resources"
      end

      digest = Fingerprint.of(body)
      twin = unique ? twin_of(digest) : nil

      return Landed.new(feed: twin, duplicate: true) if twin

      feed, staged = ActiveRecord::Base.transaction do
        held = already_at(key) || created(title.presence || File.basename(key))

        [ held, Staged.stage!(held, path: key, body: body, mime: type, source: source, digest: digest) ]
      end

      Landed.new(feed: feed, staged: staged, analysis: feed.analyze!(cause: cause))
    end

    def key_for(given)
      segments = given.to_s.tr("\\", "/").split("/").filter_map do |segment|
        cleaned = segment.gsub(/[[:cntrl:]]/, "").strip
        cleaned unless cleaned.empty? || cleaned == "." || cleaned == ".."
      end

      raise Unusable, "#{given} is not a usable path" if segments.empty?

      key = segments.join("/")

      raise Unusable, "that path is too long" if key.bytesize > MAX_KEY

      key
    end

    def filed(prefix, name, at: Time.current)
      "#{prefix}/#{at.utc.strftime('%Y%m%dT%H%M%S')}-#{named(name)}"
    end

    def named(given, fallback: "untitled")
      readable = given.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      base = File.basename(readable.tr("\\", "/")).gsub(/[[:cntrl:]]/, "").strip
      extension = File.extname(base)
      stem = base.delete_suffix(extension).parameterize.presence || fallback

      "#{stem.first(MAX_NAME)}#{extension.downcase.first(16)}"
    end

    private

      def already_at(key)
        placed = Reference.originals.where(locator_key: key, resource: Resource.stores)
                          .joins(:resource).order("resources.default_storage DESC", :id).first

        placed&.feed || waiting_at(key)
      end

      def twin_of(digest)
        placed = Reference.originals.where(digest: digest, gone_at: nil).order(:id).first
        return placed.feed if placed

        attachment = ActiveStorage::Attachment
          .where(name: "upload", record_type: "Feed")
          .joins(:blob)
          .where("active_storage_blobs.metadata::jsonb ->> ? = ?", Staged::DIGEST, digest)
          .order(:id).first

        attachment && Feed.files.find_by(id: attachment.record_id)
      end

      def waiting_at(key)
        attachment = ActiveStorage::Attachment
          .where(name: "upload", record_type: "Feed")
          .joins(:blob)
          .where("active_storage_blobs.metadata::jsonb ->> ? = ?", Staged::PATH, key)
          .order(:id).last

        attachment && Feed.files.find_by(id: attachment.record_id)
      end

      def created(named)
        Feed.create!(type: Feed::FILE, key: named, title: named)
      end
  end
end
