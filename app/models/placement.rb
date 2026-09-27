class Placement
  class Refused < ArgumentError; end
  class Nowhere < StandardError; end

  STEP = "placement".freeze

  attr_reader :feed, :analysis

  def self.candidates(feed)
    staged = feed.staged
    return Resource.none if staged.nil?

    Resource.placeable(staged.mime, size: staged.size).order(:key)
  end

  def initialize(feed, analysis: nil)
    @feed = feed
    @analysis = analysis || feed.analyses.open.last
  end

  def returned!
    held = feed.references.originals.first
    return nil if held.nil? || !feed.staged?
    return nil unless self.class.candidates(feed).exists?(held.resource_id)

    place!(held.resource, reason: "it replaces the file already at #{held.path}", by: "return")
  end

  def settled!
    return nil unless feed.reload.staged?

    candidates = self.class.candidates(feed)
    chosen = candidates.find_by(default_storage: true) || candidates.first

    raise Nowhere, "nothing accepts #{feed.staged.filename}, so it stays staged" if chosen.nil?

    place!(chosen, reason: chosen.default_storage? ? "default storage" : "the only place that accepts it",
                   by: "default")
  end

  def place!(resource, reason:, by: "agent")
    staged = feed.staged || raise(Refused, "feed #{feed.id} has nothing waiting to be placed")

    unless self.class.candidates(feed).exists?(resource.id)
      raise Refused, "#{resource.key} does not accept a #{staged.mime} of #{staged.size} bytes"
    end

    key = unclaimed(resource, staged.path)
    locator = upload(resource, key, staged)
    reference = recorded(resource, key, locator, staged)

    noted(reference, reason: reason, by: by)
    feed.upload.purge
    feed.references.reset

    reference
  end

  private

    def upload(resource, key, staged)
      io = staged.download
      locator = resource.upload(key, io)

      staged.source.present? ? locator.merge(Staged::SOURCE => staged.source) : locator
    ensure
      io&.close
    end

    def recorded(resource, key, locator, staged)
      reference = Reference.find_or_initialize_by(resource: resource, locator_key: key)

      reference.changed_at = Time.current if reference.persisted?
      reference.feed = feed
      reference.role = Reference::ORIGINAL
      reference.locator = locator
      reference.mime = staged.mime
      reference.version = resource.version_for(locator)
      reference.analyzed_at = staged.analyzed_at
      reference.digest = staged.digest
      reference.save!
      reference
    end

    def unclaimed(resource, path)
      claimed = Reference.where(resource: resource, locator_key: path).where.not(feed_id: feed.id)
      return path unless claimed.exists?

      extension = File.extname(path)

      "#{path.delete_suffix(extension)}-#{feed.id}#{extension}"
    end

    def noted(reference, reason:, by:)
      return if analysis.nil?

      now = Time.current.iso8601(3)

      analysis.write_step!(STEP, {
        "started_at" => now, "finished_at" => now,
        "result" => { "resource" => reference.resource.key, "path" => reference.locator_key,
                      "by" => by, "reason" => reason.to_s.truncate(500) }
      })
      analysis.log_info(STEP, reference.path, by, reason)
    end
end
