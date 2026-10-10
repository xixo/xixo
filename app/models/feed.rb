class Feed < ApplicationRecord
  self.inheritance_column = nil

  FILE = "xixo:file".freeze
  NOTE = "xixo:note".freeze
  ADDRESS = "xixo:address".freeze
  TAG = "xixo:tag".freeze
  MIME = "xixo:mime".freeze

  TYPES = [ FILE, NOTE, ADDRESS, TAG, MIME ].freeze
  SINGLETON = [ TAG, ADDRESS, MIME ].freeze
  FACETS = [ TAG, MIME ].freeze
  ORIGINS = %w[resource feed].freeze

  DEPTH = 4
  MAX_KEY = 900
  MONTHS = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec".freeze
  UNTAGGABLE = %r{[@:/]|\A[\w-]+(\.[\w-]+)+\z|\Afeed\s*\d+\z}i
  DATED = %r{\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}|\b(#{MONTHS})[a-z]*\.?,?\s+\d|\d(st|nd|rd|th)?\s+(#{MONTHS})}i
  TIMEOUT = 10.minutes
  ASK_TIMEOUT = 2.minutes
  MIN_TIMEOUT = 1.minute
  MAX_TIMEOUT = 1.day
  GIST = %w[title note].freeze
  GONE_FOR = 30.days

  RESERVED = %w[
    mcp graphql graphiql auth connect references feeds resources runs settings
    jobs up assets vite rails cable audit uploads share analyses
    recede resume refresh
  ].freeze

  ADDRESS_KEY = %r{\A/[a-z0-9][a-z0-9-]{0,62}\z}

  include TenantScoped

  has_many :references, -> { oldest_first }, class_name: "Reference", dependent: :destroy,
                                             inverse_of: :feed
  has_many :resources, through: :references
  has_many :analyses, -> { order(:id) }, dependent: :destroy, inverse_of: :feed
  has_one :schedule, dependent: :destroy
  has_many :passages, -> { order(:position) }, inverse_of: :feed
  has_one_attached :upload, dependent: :purge

  belongs_to :parent, class_name: "Feed", optional: true
  has_many :children, -> { order(:id) }, class_name: "Feed", foreign_key: :parent_id,
                                         inverse_of: :parent, dependent: :destroy

  validates :type, presence: true, inclusion: { in: TYPES }
  validates :key, presence: true, length: { maximum: MAX_KEY }
  validates :origin, inclusion: { in: ORIGINS }
  validates :key, uniqueness: { scope: [ :tenant_id, :type ] }, if: :singleton?
  validates :timeout, numericality: { only_integer: true, greater_than_or_equal_to: MIN_TIMEOUT.to_i,
                                      less_than_or_equal_to: MAX_TIMEOUT.to_i }, allow_nil: true
  validate :an_address_is_shaped_like_one, if: :address?
  validate :an_address_is_not_spoken_for, if: :address?
  validate :the_origin_does_not_change, on: :update

  scope :files, -> { where(type: FILE) }
  scope :addresses, -> { where(type: ADDRESS) }
  scope :tags, -> { where(type: TAG) }
  scope :by_use, lambda {
    order(Arel.sql("(SELECT COUNT(*) FROM feed_edges WHERE feed_edges.a_id = feeds.id " \
                   "OR feed_edges.b_id = feeds.id) DESC"), :key)
  }
  scope :mimes, -> { where(type: MIME) }
  scope :synced, -> { where(origin: "resource") }
  scope :minted, -> { where(origin: "feed") }
  scope :unembedded, -> { where(embedded_at: nil).order(:id) }
  scope :unsummarized, -> {
    where(type: FILE).where(id: Reference.where.not(analyzed_at: nil).select(:feed_id))
                     .where.not(id: Analysis.where("steps ? 'summary'").select(:feed_id))
                     .where.not(id: Analysis.open.select(:feed_id))
  }
  scope :by_key, ->(value) { where(key: value.to_s) }
  scope :expired, -> { where(expires_at: ..Time.current) }
  scope :unattended, lambda {
    files.where(parent_id: nil, expires_at: nil, note: [ nil, "" ])
         .where.not(id: Edge.where(inferred: false).where.not(b_id: Feed.mimes.select(:id)).select(:a_id))
         .where.not(id: Edge.where(inferred: false).where.not(a_id: Feed.mimes.select(:id)).select(:b_id))
  }

  normalizes :title, with: ->(value) { value.to_s.squish.presence }

  before_destroy :forget_edges

  after_commit :index_for_search, on: [ :create, :update ]
  after_commit :reconsider_embedding, on: :update
  after_commit :remove_from_search, on: :destroy

  def file? = type == FILE
  def note? = type == NOTE
  def address? = type == ADDRESS
  def tag? = type == TAG
  def mime? = type == MIME
  def singleton? = SINGLETON.include?(type)

  def to_param = tag? || address? ? key : id.to_s

  def self.tag_name(key) = key.to_s.tr("_", " ").squish

  def self.tag_named(key) = tags.find_by("lower(key) = ?", tag_name(key).downcase)

  def self.tag!(key) = tag_named(key) || singleton!(TAG, tag_name(key))

  def self.fit_tag?(name, feed = nil)
    held = tag_name(name)
    characters = held.scan(/[[:alnum:]]/)
    digits = characters.count { |character| character.match?(/\d/) }

    return false if characters.size < 2 || held.length > MAX_KEY
    return false if digits * 2 > characters.size || held.match?(DATED) || held.match?(UNTAGGABLE)

    feed.nil? || !feed.named_by?(held)
  end
  def self.mime!(key) = singleton!(MIME, key)

  def self.lonely(ids = nil)
    held = where(type: FACETS, note: [ nil, "" ]).where.not(id: Edge.select(:a_id)).where.not(id: Edge.select(:b_id))
    ids.nil? ? held : held.where(id: ids)
  end

  def self.forget_lonely!(ids = nil) = lonely(ids).destroy_all

  def self.long_gone
    unattended.where(id: Reference.originals.select(:feed_id))
              .where.not(id: Analysis.open.select(:feed_id))
              .where.not(id: Reference.originals.where("gone_at IS NULL OR gone_at > ?", GONE_FOR.ago).select(:feed_id))
  end

  def self.placeless(ids)
    unattended.where(id: ids)
              .where.not(id: Reference.originals.select(:feed_id))
              .where.not(id: ActiveStorage::Attachment.where(record_type: name, name: "upload").select(:record_id))
  end

  def self.singleton!(type, key)
    where(type: type).find_by(key: key.to_s) ||
      where(type: type).create_or_find_by!(key: key.to_s) { |feed| feed.title = key.to_s }
  end

  def self.reindex!(feeds)
    SearchIndex.index_all(for_indexing.where(id: feeds.map(&:id)))
  end

  def self.address(key)
    addresses.by_key(key.to_s.start_with?("/") ? key : "/#{key}").first
  end

  def self.search(query, type: nil, mime: nil, tag: nil, limit: 50)
    ids = SearchIndex.search(query, type: type, mime: mime, tag: tag, limit: limit)
    return none if ids.empty?

    where(id: ids).in_order_of(:id, ids)
  end

  def self.found(query, type: nil, mime: nil, tag: nil, limit: 50, from: 0)
    held = SearchIndex.page(query, type: type, mime: mime, tag: tag, limit: limit, from: from)
    ids = held[:ids]
    nodes = ids.empty? ? [] : where(id: ids).in_order_of(:id, ids).to_a

    Page.at(nodes, from: from, total: held[:total])
  end

  def self.for_indexing
    includes(:references, :analyses, children: :analyses)
  end

  def self.family_tags_for(feeds)
    owners = Hash.new { |held, id| held[id] = [] }
    feeds.each { |feed| feed.family.each { |member| owners[member.id] << feed.id } }

    found = Hash.new { |held, id| held[id] = [] }
    return found if owners.empty?

    pairs = Edge.where(a_id: owners.keys, b_id: tags.select(:id)).pluck(:a_id, :b_id) +
            Edge.where(b_id: owners.keys, a_id: tags.select(:id)).pluck(:b_id, :a_id)
    keys = where(id: pairs.map(&:last)).pluck(:id, :key).to_h

    pairs.each { |member, tag| owners[member].each { |feed| found[feed] << keys.fetch(tag) } }
    found.transform_values! { |keys| keys.uniq.sort }
  end

  def self.referencing(resource_id)
    where(id: Reference.where(resource_id: resource_id).select(:feed_id))
  end

  def self.referenced
    where(id: Reference.select(:feed_id))
  end

  def self.tagged(key) = filed_under(TAG, key)

  def self.filed_under(type, key)
    held = where(type: type).by_key(key).first

    held.nil? ? none : connected_to(held)
  end

  def self.connected_to(feeds)
    ids = Array.wrap(feeds).map(&:id)

    where(id: Edge.where(b_id: ids).select(:a_id))
      .or(where(id: Edge.where(a_id: ids).select(:b_id)))
  end

  def self.under(folder)
    prefix = folder.to_s.delete_prefix("/").chomp("/")
    return all if prefix.empty?

    where(id: Reference.under(prefix).select(:feed_id))
  end

  def self.matching(selector)
    selector = selector.to_h.with_indifferent_access
    scope = all
    scope = scope.where(id: selector[:id]) if selector[:id].present?
    scope = scope.where(type: selector[:type]) if selector[:type].present?
    scope = scope.where(key: selector[:key]) if selector[:key].present?
    scope = scope.where(id: Reference.where(mime: selector[:mime]).select(:feed_id)) if selector[:mime].present?
    scope = scope.where(id: tagged(selector[:tag]).select(:id)) if selector[:tag].present?
    scope = scope.referencing(selector[:resource_id]) if selector[:resource_id].present?
    scope = scope.under(selector[:folder]) if selector[:folder].present?
    scope = scope.where(created_at: moment(selector[:since])..) if selector[:since].present?
    scope = scope.where(created_at: ...moment(selector[:before])) if selector[:before].present?
    scope = scope.where(id: search(selector[:query]).ids) if selector[:query].present?
    scope
  end

  def self.moment(value)
    return value if value.respond_to?(:to_time) && !value.is_a?(String)

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{value} is not a date")
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{value} is not a date"
  end

  AGENT_SCOPES = %w[
    xixo:catalog:read xixo:catalog:write xixo:web:read xixo:resources:read
  ].freeze

  FILING_SCOPES = %w[
    xixo:catalog:read xixo:catalog:write xixo:resources:read
  ].freeze

  WORLD_SCOPES = %w[
    xixo:web:read xixo:web:keep xixo:resources:read
  ].freeze

  ASKING_SCOPES = %w[
    xixo:catalog:read xixo:catalog:write xixo:web:read xixo:web:keep xixo:resources:read
  ].freeze

  def time_allowed
    (timeout.presence || TIMEOUT.to_i).seconds
  end

  def grant(scopes: AGENT_SCOPES, speaking_for: nil)
    Grant.new(
      tenant: tenant,
      claims: Masks::Client::Claims.new(
        "sub" => "feed:#{key}",
        "scope" => scopes.join(" "),
        "tenant" => { "subdomain" => tenant.subdomain }
      ),
      agent: true,
      speaking_for: speaking_for
    )
  end

  def edges
    Edge.touching(id)
  end

  def connected
    Feed.connected_to(self)
  end

  def tags
    connected.tags
  end

  def mimes
    connected.mimes
  end

  def connect!(other, inferred: false)
    Edge.between!(self, other, inferred: inferred)
  end

  def named_by?(name)
    wanted = Feed.tag_name(name).downcase

    [ key, title ].compact.any? do |own|
      stem = Feed.tag_name(File.basename(own, ".*")).downcase

      own.downcase == wanted || (stem.match?(/\d/) && wanted.include?(stem))
    end
  end

  def tag_with!(names)
    return if singleton?

    held = names.filter_map { |name| Feed.tag!(name) if Feed.fit_tag?(name, self) }.uniq
    kept = held.map(&:id)

    transaction do
      dropped = edges.inferred.where.not(a_id: kept).where.not(b_id: kept)
      loose = dropped.pluck(:a_id, :b_id).flatten - [ id ]
      dropped.delete_all
      held.each { |tag| connect!(tag, inferred: true) }
      Feed.forget_lonely!(loose)
    end
  end

  def disconnect!(other)
    Edge.between(self, other)&.destroy
    Feed.forget_lonely!([ id, other.id ])
  end

  def destroy_if_empty!
    destroy! if file? && references.originals.none?
  end

  def inherit!(other)
    other.edges.find_each do |edge|
      held = edge.other_than(other)
      connect!(held, inferred: edge.inferred) unless held.id == id
    end
    keep_note_from(other)
  end

  def absorb!(other, moved)
    ids = moved.pluck(:id)

    transaction do
      if other.references.originals.where.not(id: ids).none?
        inherit!(other)
        outlast!(other)
      end

      Reference.where(id: ids).update_all(feed_id: id, updated_at: Time.current)
      other.reload.destroy_if_empty!
    end
  end

  def keep_note_from(other)
    return if other.note.blank?
    return update!(note: other.note) if note.blank?
    return if note.include?(other.note)

    update!(note: [ note, other.note ].join("\n\n"))
  end

  def outlast!(other)
    return if expires_at.nil?

    update!(expires_at: other.expires_at && [ expires_at, other.expires_at ].max)
  end

  def reference
    references.find { |held| held.role == Reference::ORIGINAL }
  end

  def resource
    reference&.resource
  end

  def locator
    reference&.locator || {}
  end

  def locator_key
    reference&.locator_key
  end

  def mime
    reference&.mime || staged&.mime
  end

  def staged
    upload.attached? ? Staged.new(self) : nil
  end

  def staged?
    upload.attached?
  end

  def asked?
    note? && analyses.exists?(cause: "ask")
  end

  def source_for(destination)
    references.originals.find { |reference| reference.resource_id != destination.id }
  end

  def copy_at(destination)
    references.originals.find { |reference| reference.resource_id == destination.id }
  end

  def download
    raise ArgumentError, "no reference" if reference.nil?

    reference.download
  end

  def analysis
    return analyses.settled.last unless analyses.loaded?

    analyses.select(&:settled?).last
  end

  def family
    @family ||= [ self, *children ]
  end

  def reload(*)
    @family = nil
    @outline = nil
    super
  end

  def analyzed_at
    references.maximum(:analyzed_at) || staged&.analyzed_at || (analysis&.finished_at unless file?)
  end

  Turn = Data.define(:analysis, :question, :said)

  KEPT_FOR = 30.days
  FOREVER = "forever".freeze
  LONGEST = 3650

  def self.expiry_for(lasts, default: nil)
    given = lasts.to_s.strip.downcase
    return default&.from_now if given.empty?
    return nil if given == FOREVER

    days = Integer(given, exception: false)
    raise ArgumentError, "lasts is #{FOREVER} or a number of days up to #{LONGEST}" unless days&.between?(1, LONGEST)

    days.days.from_now
  end

  def lasts!(lasts, default: nil)
    update!(expires_at: Feed.expiry_for(lasts, default: default))
    self
  end

  def analyze!(cause: "manual")
    return ask!(conversation.last&.question || key || title) if cause.to_s == "ask"

    Analysis.open!(feed: self, cause: cause).tap do |held|
      AnalyzeFeedJob.enqueue(self, held)
    end
  end

  def ask!(question, about: nil)
    raise ArgumentError, "only a note can be asked" unless note?
    raise ArgumentError, "#{title || key} is still being answered" if analyses.open.exists?(cause: "ask")

    Analysis.create!(feed: self, cause: "ask", question: question.to_s.squish, about: about,
                     deadline: Analysis.default_deadline, steps: {}).tap do |held|
      AnalyzeFeedJob.set(priority: Analysis::ASKED_PRIORITY).perform_later(tenant_id, id, held.id)
    end
  end

  def conversation(through: nil)
    turns = analyses.where(cause: "ask").reorder(:id)
    turns = turns.where(id: ..through.id) if through

    turns.map do |held|
      said = held.step_result("answer").to_h["said"].presence || held.step_result("text").presence
      Turn.new(analysis: held, question: held.question.presence || key || title, said: said)
    end
  end

  def announce_analyzed!
    XixoSchema.subscriptions.trigger(:feed_analyzed, {}, self, scope: tenant_id)
    XixoSchema.subscriptions.trigger(:feed_analyzed, { id: id.to_s }, self, scope: tenant_id)
  end

  def outline
    @outline ||= Outline.of(analysis&.own_text, stored: analysis&.step_result("outline"))
  end

  def described_text
    family.flat_map { |held| held.analysis&.described || [] }.uniq.join("\n").presence
  end

  def readable_text
    strings = family.filter_map { |held| held.analysis&.extracted }

    collected = []
    collect_strings(strings) { |value| collected << value }
    collected.uniq.join("\n").presence
  end

  def summaries
    family.filter_map { |held| held.analysis&.summary }.uniq
  end

  def summary
    analysis&.summary
  end

  def family_tags
    Feed.family_tags_for([ self ])[id]
  end

  def depth
    held = 0
    node = self

    while (node = node.parent) && held < DEPTH
      held += 1
    end

    held
  end

  def children_ready?
    children.all? { |child| child.analyzed_at.present? }
  end

  private

    def forget_edges
      neighbors = edges.pluck(:a_id, :b_id).flatten.uniq - [ id ]
      edges.delete_all
      Feed.forget_lonely!(neighbors)
    end

    def index_for_search
      SearchIndex.index(Feed.for_indexing.find_by(id: id) || self)
    end

    def reconsider_embedding
      return if (saved_changes.keys & GIST).empty?

      Feed.where(id: id).where.not(embedded_at: nil).update_all(embedded_at: nil)
    end

    def remove_from_search
      SearchIndex.delete(self)
      PassageIndex.delete_for(self)
    end

    def collect_strings(value, &block)
      case value
      when String then yield value if value.length > 1
      when Array then value.each { |v| collect_strings(v, &block) }
      when Hash then value.each_value { |v| collect_strings(v, &block) }
      end
    end

    def an_address_is_shaped_like_one
      return if key.to_s.match?(ADDRESS_KEY)

      errors.add(:key, "is a slash and then letters, numbers and dashes")
    end

    def an_address_is_not_spoken_for
      return unless RESERVED.include?(key.to_s.delete_prefix("/").downcase)

      errors.add(:key, "is a path xixo already answers to")
    end

    def the_origin_does_not_change
      return unless origin_changed? && origin_was == "resource"

      errors.add(:origin, "cannot be changed — a synced feed was not minted")
    end
end
