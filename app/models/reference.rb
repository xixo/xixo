class Reference < ApplicationRecord
  self.table_name = "feed_references"

  ORIGINAL = "original".freeze
  PREVIEW = "preview".freeze
  THUMBNAIL = "thumbnail".freeze

  ROLES = [ ORIGINAL, PREVIEW, THUMBNAIL ].freeze
  DERIVED = [ PREVIEW, THUMBNAIL ].freeze

  RETRY_FAILED_AFTER = 1.day

  include TenantScoped

  belongs_to :feed
  belongs_to :resource

  validates :role, inclusion: { in: ROLES }
  validates :locator_key, uniqueness: { scope: [ :tenant_id, :resource_id ] }, allow_nil: true

  scope :oldest_first, -> { order(:created_at, :id) }
  scope :originals, -> { where(role: ORIGINAL) }
  scope :derived, -> { where(role: DERIVED) }
  scope :in_role, ->(role) { where(role: role.to_s) }
  scope :reachable_by, ->(grant) { where(resource: Resource.reachable_by(grant)) }

  scope :joinable, -> {
    originals.where(gone_at: nil, kept_apart: false)
             .where.not(digest: [ nil, Fingerprint::EMPTY ])
             .where(resource: Resource.active.external)
  }

  scope :under, ->(prefix) {
    escaped = sanitize_sql_like(prefix.to_s.delete_prefix("/").chomp("/"))

    where("locator_key = :exact OR locator_key LIKE :under ESCAPE '\\'",
          exact: prefix, under: "#{escaped}/%")
  }

  after_commit :reindex_feed
  after_destroy_commit :forget_bytes_xixo_made

  def self.discover!(resource:, locator:, locator_key:, mime: nil, title: nil, role: ORIGINAL)
    reference = find_or_initialize_by(resource: resource, locator_key: locator_key)
    named = title.presence || File.basename(locator_key.to_s).presence || locator_key.to_s

    if reference.feed.nil?
      reference.feed = Feed.create!(type: Feed::FILE, key: named, title: named)
    end

    reference.role = role
    reference.locator = locator
    reference.mime = mime.presence || MimeType.for_filename(locator_key)
    reference.note_version!(resource.version_for(locator))
    reference.save!
    reference
  end

  def self.record!(feed:, resource:, locator:, locator_key:, role: ORIGINAL,
                   mime: nil, source_version: nil)
    reference = find_or_initialize_by(resource: resource, locator_key: locator_key)

    if reference.persisted? && reference.feed_id != feed.id
      reference.move_to!(feed)
    else
      reference.feed = feed
    end

    reference.role = role
    reference.locator = locator
    reference.mime = mime.presence || reference.mime || MimeType.for_filename(locator_key)
    reference.version = resource.version_for(locator)
    reference.source_version = source_version
    reference.save!
    reference
  end

  def note_version!(reported)
    return self if reported.blank?

    if version.present? && version != reported
      self.changed_at = Time.current
      self.analyzed_at = nil
      self.digest = nil
      self.kept_apart = false
    end

    self.version = reported
    self
  end

  def awaiting_analysis?
    return false if analyzed_at.present?

    attempts = feed.analyses.unscope(:order).where(created_at: (changed_at || created_at)..)
    return false if attempts.open.exists?

    attempts.where(status: "failed", finished_at: RETRY_FAILED_AFTER.ago..).none?
  end

  def derived?
    DERIVED.include?(role)
  end

  def analyzed!
    update!(analyzed_at: Time.current)
  end

  def stale_against?(source)
    source_version.present? && source.version.present? && source_version != source.version
  end

  def move_to!(destination)
    return self if destination.id == feed_id

    previous = feed

    transaction do
      if destination.references.exists?(resource_id: resource_id, locator_key: locator_key)
        destroy!
      else
        update!(feed: destination)
      end

      previous.reload.destroy_if_empty!
    end

    self
  end

  def split!
    left = feed

    transaction do
      move_to!(Feed.create!(type: left.type, key: left.key, title: left.title, expires_at: left.expires_at))
      feed.inherit!(left)
    end

    self
  end

  def leave!
    return self if feed.references.originals.where.not(id: id).none?

    split!
  end

  def fingerprint!
    io = download
    found = Fingerprint.of(io)
    return false if Reference.where(id: id, digest: nil, version: version).update_all(digest: found).zero?

    self.digest = found
    true
  ensure
    io.close if io.respond_to?(:close)
  end

  def twins
    Reference.joinable.where(digest: digest, resource: Resource.where(owner_subject: resource.owner_subject))
  end

  def survivor
    Feed.where(id: twins.select(:feed_id)).order(:id).first
  end

  def settle!
    return feed unless Reference.joinable.exists?(id: id)

    kept, absorbed = transaction do
      Fingerprint.lock!(digest)

      held = survivor
      others = Feed.where(id: twins.select(:feed_id)).where.not(id: held.id)
                   .where.not(id: Analysis.open.select(:feed_id)).order(:id).to_a

      others.each { |other| held.absorb!(other, twins.where(feed_id: other.id)) }
      [ held, others ]
    end

    joined(kept, absorbed) if absorbed.any?
    reload
    kept
  end

  def download
    resource.download(locator)
  end

  def path
    [ resource.key, locator_key ].compact.join("/")
  end

  def filename
    File.basename(locator_key.to_s).presence || "feed-#{feed_id}"
  end

  def content_type
    mime.presence || Rack::Mime.mime_type(File.extname(filename), "application/octet-stream")
  end

  private

    def joined(kept, absorbed)
      Feed.reindex!([ kept ])

      absorbed.each do |other|
        AuditEvent.record(
          channel: "job", action: "join_feeds", status: "ok",
          grant: nil, context: { remote_ip: nil, request_id: nil }, feed: kept,
          told: "joined #{other.title || other.key} into #{kept.title || kept.key}, which holds the same bytes",
          arguments: { "survivor" => kept.id, "absorbed" => other.id, "digest" => digest }
        )
      end

      return if kept.analyses.open.exists? || kept.analyses.where(status: "done").exists?

      kept.analyze!(cause: "sync")
    end

    def forget_bytes_xixo_made
      store = Resource.find_by(id: resource_id)
      return unless store&.internal?
      return if Reference.exists?(resource_id: resource_id, locator_key: locator_key)

      store.blobs.where(key: locator_key).delete_all
    end

    def reindex_feed
      subject = Feed.find_by(id: feed_id)
      return if subject.nil?

      SearchIndex.index(subject)
      Feed.where(id: feed_id).where.not(embedded_at: nil).update_all(embedded_at: nil)
    end
end
