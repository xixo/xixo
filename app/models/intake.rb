class Intake
  class Unusable < StandardError; end

  MAX_KEY = Feed::MAX_KEY
  MAX_NAME = 180

  Landed = Data.define(:feed, :staged, :analysis) do
    def initialize(feed:, staged: nil, analysis: nil) = super

    def duplicate = staged.nil?
  end

  class << self
    def write!(path:, body:, mime: nil, title: nil, source: nil, cause: "upload", unique: false, grant: nil)
      key = key_for(path)
      type = mime.presence || MimeType.for_filename(key)
      size = body.is_a?(String) ? body.bytesize : body.size

      unless Resource.placeable(type, size: size).exists?
        raise Unusable, "nowhere accepts a #{type} of #{size} bytes — attach storage on Resources"
      end

      digest = Fingerprint.of(body)

      feed, staged = ActiveRecord::Base.transaction do
        Fingerprint.lock!(digest) if unique

        twin = twin_of(digest, grant) if unique
        next [ twin, nil ] if twin

        held = already_at(key) || created(title.presence || File.basename(key))

        [ held, Staged.stage!(held, path: key, body: body, mime: type, source: source, digest: digest) ]
      end

      return Landed.new(feed: feed) if staged.nil?

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

      def twin_of(digest, grant)
        placed = Reference.joinable.where(digest: digest, resource: Resource.visible_to(grant).shared)
                          .order(:id).first

        placed&.feed || waiting(Staged::DIGEST, digest)
      end

      def waiting_at(key) = waiting(Staged::PATH, key)

      def waiting(field, value)
        attachment = ActiveStorage::Attachment
          .where(name: "upload", record_type: "Feed")
          .joins(:blob)
          .where("active_storage_blobs.metadata::jsonb ->> ? = ?", field, value)
          .order(:id).last

        attachment && Feed.files.find_by(id: attachment.record_id)
      end

      def created(named)
        Feed.create!(type: Feed::FILE, key: named, title: named)
      end
  end
end
