class Resource < ApplicationRecord
  class Failed < StandardError; end
  class Unusable < Failed; end
  class Refused < ArgumentError; end

  include TenantScoped

  serialize :credentials, coder: JSON, type: Hash
  encrypts :credentials

  has_many :references, dependent: :destroy

  belongs_to :via, class_name: "Resource", optional: true
  has_many :reached_through, class_name: "Resource", foreign_key: :via_id,
                             inverse_of: :via, dependent: :restrict_with_error

  DECLARATIONS = Rails.root.join("config/resources.yml")

  MINIMUM_SYNC_INTERVAL = 1.minute
  SYNC_ABANDONED_AFTER = 6.hours
  CHECKED_EVERY = 6.hours
  PROBE_ABANDONED_AFTER = 15.minutes
  MAX_HOPS = 4
  MAX_TEXT = 100_000
  GLIMPSE_BYTES = MAX_TEXT * 4
  DEFAULTABLE = { storage: :default_storage, inference: :default_inference }.freeze
  INTERNAL = { children: "Extracted children", derived: "Previews and thumbnails" }.freeze
  INTERNAL_MARK = "internal".freeze

  TYPES = %w[
    s3 filesystem webdav caldav carddav imap rss web openai-compatible oauth-google database
    search curl mcp github notion slack microsoft-graph git weather places tailnet feedback
  ].freeze

  validates :key, presence: true,
                  uniqueness: { scope: [ :tenant_id, :type ], case_sensitive: true }
  validates :sync_interval, numericality: {
    greater_than_or_equal_to: MINIMUM_SYNC_INTERVAL.to_i
  }, allow_nil: true
  validate :an_internal_key_is_only_the_apps_own
  validate :an_internal_store_stays_as_xixo_keeps_it
  validate :only_a_syncable_resource_keeps_a_schedule
  validate :a_default_is_a_resource_that_can_be_one
  validate :via_is_a_transport
  validate :via_is_honored
  validate :via_is_this_tenants
  validate :via_leads_somewhere
  validate :a_transport_in_use_is_not_archived

  before_save :start_the_schedule, if: :sync_interval_changed?
  before_save :mirror_what_it_serves
  after_commit :summarize_what_went_without, on: %i[create update], if: :newly_inferring?

  scope :active, -> { where(archived_at: nil) }
  scope :attended, -> { where.not(type: "database", key: INTERNAL.keys.map(&:to_s)) }
  scope :external, -> { where.not(type: "database").or(where.not(key: INTERNAL.keys.map(&:to_s))) }
  scope :shared, -> { where(owner_subject: nil) }
  scope :reachable_by, ->(grant) { where(owner_subject: [ nil, grant&.speaks_for ].uniq) }
  scope :visible_to, ->(grant) { attended.active.reachable_by(grant) }
  scope :scheduled, -> { active.where.not(sync_interval: nil) }
  scope :not_syncing, -> {
    where(sync_started_at: nil).or(where(sync_started_at: ...SYNC_ABANDONED_AFTER.ago))
  }
  scope :probing, -> { where(probing_since: PROBE_ABANDONED_AFTER.ago..) }
  scope :due_for_sync, -> { scheduled.not_syncing.where(next_sync_at: ..Time.current) }
  scope :due_for_check, -> {
    attended.active.not_syncing.where(checked_at: nil).or(
      attended.active.not_syncing.where(checked_at: ...CHECKED_EVERY.ago)
    )
  }

  class << self
    def credential_fields
      attaching[:fields].select { |field| field[:secret] || field[:held] == :credentials }.map { |field| field[:name] }
    end

    def transport!(key, grant)
      capable_of(:transport).reachable_by(grant).find_by(key: key.to_s) ||
        raise(Refused, "#{key} is not a transport here")
    end

    def sti_name
      return super if self == Resource

      name.demodulize.underscore.dasherize
    end

    def find_sti_class(type_name)
      return super if type_name.include?("::")

      const_get("Resource::#{type_name.tr('-', '_').camelize}")
    end

    def serves(*names)
      @serves = names.map(&:to_s) if names.any?
      @serves ||= []
    end

    def accepts(*patterns)
      @accepts = patterns.map(&:to_s) if patterns.any?
      @accepts ||= []
    end

    def up_to(bytes = nil)
      @up_to = bytes.to_i if bytes
      @up_to
    end

    def capabilities
      serves.map(&:to_sym)
    end

    def serving
      { "capabilities" => serves, "accepts" => accepts, "up_to" => up_to }.compact
    end

    def command_schema
      {}
    end

    # What a type needs before it can answer, declared rather than written down,
    # so a form is rendered from the type instead of kept in step with it. Nil
    # means a type nobody attaches by hand.
    def attaching
      nil
    end

    def attachable
      TYPES.filter_map do |name|
        held = find_sti_class(name)

        held if held.attaching.present?
      end
    end

    def delegated?
      false
    end

    def notices_what_is_gone?
      true
    end

    def walks_changes?
      false
    end

    def routable?
      false
    end

    def declared_only?
      false
    end

    def field(name, label, kind: "string", required: false, secret: false, held: nil,
              value: nil, help: nil, placeholder: nil, options: nil, shown_when: nil)
      {
        name: name, label: label, kind: kind, required: required, secret: secret,
        held: held || (secret ? :credentials : :details),
        value: value, help: help, placeholder: placeholder,
        options: options, shown_when: shown_when
      }
    end

    def capable_of(capability)
      active.serving_as(capability)
    end

    def serving_as(capability)
      where("jsonb_exists(resources.serving -> 'capabilities', ?)", capability.to_s)
    end

    ACCEPTS = <<~SQL.squish.freeze
      EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(resources.serving -> 'accepts') AS pattern
        WHERE ? LIKE replace(pattern, '*', '%')
      )
    SQL

    ROOM = <<~SQL.squish.freeze
      resources.serving ->> 'up_to' IS NULL OR (resources.serving ->> 'up_to')::bigint >= ?
    SQL

    def accepting(mime, size: nil)
      scope = active.shared.where(ACCEPTS, mime.to_s)

      size.nil? ? scope : scope.where(ROOM, size.to_i)
    end

    def stores
      capable_of(:storage).where.not(key: INTERNAL.keys.map(&:to_s))
    end

    def placeable(mime, size: nil)
      stores.accepting(mime, size: size)
    end

    def internal!(key)
      held = Resource::Database.find_by(key: key.to_s) || Resource::Database.create_or_find_by!(key: key.to_s) do |made|
        made.name = INTERNAL.fetch(key.to_sym)
        made.details = { INTERNAL_MARK => true }
      end
      held.name ||= INTERNAL.fetch(key.to_sym)
      held.details = held.details.to_h.merge(INTERNAL_MARK => true)
      held.save! if held.changed?
      held
    end

    def declarations
      held = DECLARATIONS.exist? ? YAML.safe_load(ERB.new(DECLARATIONS.read).result, aliases: true).to_h : {}

      Tailnet.declared.merge(held[Rails.env].to_h)
    end

    # Reconciles what the deployment declares, never what somebody attached — a
    # declaration this file drops is left standing rather than deleted underneath
    # whoever is using it.
    def declare!(held = declarations)
      held.filter_map do |key, spec|
        spec = spec.to_h.stringify_keys
        klass = find_sti_class(spec.fetch("type"))

        settled(klass.find_or_initialize_by(key: key.to_s), klass, spec)
      end
    end

    def settled(resource, klass, spec)
      details, credentials = klass.declared_only? ? [ {}, {} ] : Settings.for(klass, spec["settings"])

      resource.name = spec["name"].presence || key_titled(resource.key)
      resource.details = details
      resource.credentials = credentials
      resource.via = spec["via"].present? ? Resource.capable_of(:transport).find_by!(key: spec["via"].to_s) : nil
      resource.sync_interval = spec["sync_interval"] if spec.key?("sync_interval")
      resource.save!

      DEFAULTABLE.each_key do |capability|
        resource.make_default_for!(capability) if spec["default_#{capability}"]
      end

      resource
    end

    def key_titled(key)
      key.to_s.tr("-_", "  ").humanize
    end

    def restate!
      unscoped.in_batches.each_record do |resource|
        held = resource.class.serving
        next if resource.serving == held

        resource.update_columns(serving: held)
      end
    end

    def browser(grant)
      capable_of(:browser).reachable_by(grant).order(Arel.sql("resources.owner_subject NULLS FIRST"), :id).first
    end

    def default_for(capability)
      active.find_by(DEFAULTABLE.fetch(capability) => true)
    end

    def default_for!(capability)
      default_for(capability) ||
        raise(ArgumentError, "this tenant has no default #{capability} resource")
    end

    def default_storage = default_for(:storage)
    def default_storage! = default_for!(:storage)
    def default_inference = default_for(:inference)
    def default_inference! = default_for!(:inference)

    def for_role(role)
      best_inference { |resource| resource.serves_role?(role) }
    end

    def for_declared_role(role)
      best_inference { |resource| resource.declares_role?(role) }
    end

    def best_inference
      candidates = capable_of(:inference).shared.select { |resource| yield(resource) }

      candidates.find(&:default_inference?) || candidates.first
    end
  end

  def capabilities
    self.class.capabilities
  end

  def internal?
    is_a?(Resource::Database) && INTERNAL.key?(key.to_s.to_sym) && details.to_h[INTERNAL_MARK] == true
  end

  def storage?
    capabilities.include?(:storage)
  end

  def inference?
    capabilities.include?(:inference)
  end

  def transport?
    capabilities.include?(:transport)
  end

  def storage!
    raise ArgumentError, "#{key} is not storage — it cannot be an export destination" unless storage?

    self
  end

  def serves_role?(_role)
    false
  end

  def time_allowed
    nil
  end

  def declares_role?(_role)
    false
  end

  def reach!(_target)
    raise NotImplementedError, "#{self.class.sti_name} is not a transport"
  end

  def covers
    []
  end

  def reached(target)
    via.present? ? via.reach!(target) : target
  end

  def through
    via&.covers
  end

  def make_default_for!(capability)
    column = DEFAULTABLE.fetch(capability)

    unless capabilities.include?(capability)
      raise ArgumentError, "#{key} is not #{capability} — it cannot be the default"
    end

    transaction do
      Resource.where(column => true).where.not(id: id).update_all(column => false)
      update!(column => true)
    end

    self
  end

  def make_default!(named = nil)
    served = DEFAULTABLE.keys & capabilities
    raise ArgumentError, "#{key} serves neither storage nor inference, so it is no default" if served.empty?
    raise ArgumentError, "#{key} serves #{served.to_sentence}; say which it is the default for" if named.blank? && served.many?

    capability = named.present? ? served.find { |held| held.to_s == named.to_s } : served.first
    raise ArgumentError, "#{key} does not serve #{named}" if capability.nil?

    make_default_for!(capability)
    capability
  end

  def make_default_storage! = make_default_for!(:storage)
  def make_default_inference! = make_default_for!(:inference)

  def accepts
    self.class.accepts
  end

  def up_to
    self.class.up_to
  end

  def accepts?(mime, size: nil)
    return false unless accepts.any? { |pattern| File.fnmatch?(pattern, mime.to_s) }

    up_to.nil? || size.nil? || size.to_i <= up_to
  end

  def describe
    {
      type: self.class.sti_name,
      key: key,
      name: name,
      capabilities: capabilities,
      accepts: accepts,
      up_to: up_to,
      commands: self.class.command_schema
    }
  end

  def check!
    raise NotImplementedError, "#{self.class} does not implement #check!"
  end

  def check
    checked do
      answers!
      next record_check(nil) unless probes?

      update_columns(probing_since: Time.current)
      CheckResourceJob.perform_later(id)
    end
  end

  def probe
    checked do
      check!
      record_check(nil)
    end
  end

  def answers!
    check!
  end

  def probes?
    false
  end

  def checking?
    probing_since.present? && probing_since > PROBE_ABANDONED_AFTER.ago
  end

  def healthy?
    checked_at.present? && check_error.nil?
  end

  def command(name, arguments = {})
    schema = self.class.command_schema[name.to_s.to_sym]
    raise ArgumentError, "#{self.class.sti_name} has no command '#{name}'" if schema.nil?

    given = arguments.to_h.symbolize_keys.slice(*schema.keys)
    missing = schema.reject { |_, type| type.end_with?("?") }.keys - given.keys
    raise ArgumentError, "'#{name}' requires #{missing.join(', ')}" if missing.any?

    public_send(:"command_#{name}", **given)
  end

  def glimpse(key, head, size)
    text = head.to_s.dup.force_encoding(Encoding::UTF_8)
    cuts = text.bytesize >= size.to_i ? [ 0 ] : (0..3)

    readable = cuts.map { |cut| text.byteslice(0, text.bytesize - cut) }.find(&:valid_encoding?)

    if readable
      { "key" => key, "size" => size.to_i, "text" => readable.truncate(MAX_TEXT) }
    else
      { "key" => key, "size" => size.to_i, "text" => nil,
        "note" => "binary — sync it into the catalog or export it instead" }
    end
  end

  def syncable?
    respond_to?(:each_page)
  end

  def version_for(locator)
    locator.to_h["etag"].presence
  end

  def mime_for(object)
    MimeType.for_filename(locator_key_for(object))
  end

  def title_for(object)
    File.basename(locator_key_for(object))
  end

  def keep!(object, cause: "sync")
    reference = Reference.discover!(
      resource: self,
      locator: locator_for(object),
      locator_key: locator_key_for(object),
      mime: mime_for(object),
      title: title_for(object)
    )

    reference.leave! if reference.saved_change_to_changed_at?
    reference.feed.analyze!(cause: cause) if reference.awaiting_analysis?

    if cause == "sync"
      reference.update_columns(seen_at: Time.current, gone_at: nil)
    elsif reference.gone_at
      reference.update_columns(gone_at: nil)
    end

    reference
  end

  def delegated?
    false
  end

  def personal?
    owner_subject.present?
  end

  def needs_connect?
    false
  end

  def connect_path
    nil
  end

  def syncing?
    sync_started_at.present? && sync_started_at > SYNC_ABANDONED_AFTER.ago
  end

  def sync!
    raise ArgumentError, "#{self.class.sti_name} is not syncable" unless syncable?
    raise ArgumentError, "#{key} is a store xixo keeps for itself" if internal?
    return false unless claim_sync!

    Run.start!(kind: "sync", resource: self).tap do |run|
      SyncResourceJob.perform_later(tenant_id, id, run.id)
    end
  end

  def claim_sync!
    claimed = Resource.where(id: id).not_syncing.update_all(sync_started_at: Time.current)
    return false if claimed.zero?

    reload
    true
  end

  def abandon_sync!
    update_columns(
      sync_started_at: nil,
      next_sync_at: sync_interval.present? ? next_sync_after(Time.current) : nil
    )
  end

  def release_sync!
    finished = Time.current

    update_columns(
      sync_started_at: nil,
      synced_at: finished,
      next_sync_at: sync_interval.present? ? next_sync_after(finished) : nil,
      needs_connect_at: nil
    )
  end

  private

    def escaped_path(path)
      parts = path.to_s.split("/").reject(&:empty?)

      raise Resource::Failed, "#{key}: #{path} climbs out of the collection" if parts.intersect?(%w[. ..])

      parts.map { |part| ERB::Util.url_encode(part) }.join("/")
    end

    def within_prefix(asked, bounded: false)
      wanted = details["prefix"].to_s
      held = asked.to_s
      wanted, held = [ wanted, held ].map { |path| path.delete_prefix("/").chomp("/") } if bounded

      return wanted.presence if held.blank?
      return held if wanted.blank? || held == wanted || held.start_with?(bounded ? "#{wanted}/" : wanted)

      raise ArgumentError, "#{key}: #{asked} is outside #{wanted}"
    end

    def escaped_segment(value)
      held = value.to_s

      raise ArgumentError, "#{key}: #{value.inspect} does not name one thing" if held.empty? || held.in?(%w[. ..])

      ERB::Util.url_encode(held)
    end

    def kept(named)
      reference = keep!(object_for(named), cause: "keep")

      {
        "id" => reference.feed_id.to_s,
        "key" => reference.locator_key,
        "title" => reference.feed.title,
        "mime" => reference.mime,
        "version" => reference.version,
        "changed_at" => reference.changed_at,
        "new" => reference.previously_new_record?
      }
    end

    def an_internal_key_is_only_the_apps_own
      return unless INTERNAL.key?(key.to_s.to_sym)
      return if is_a?(Resource::Database) && details.to_h[INTERNAL_MARK] == true

      errors.add(:key, "#{key} is kept for a store xixo makes for itself")
    end

    def an_internal_store_stays_as_xixo_keeps_it
      return unless internal?

      errors.add(:archived_at, "cannot be set on #{key}, which xixo keeps for itself") if archived_at.present?
      errors.add(:sync_interval, "cannot be set on #{key}, which xixo keeps for itself") if sync_interval.present?

      DEFAULTABLE.each_value do |column|
        errors.add(column, "cannot be set on #{key}, which xixo keeps for itself") if public_send(:"#{column}?")
      end
    end

    def mirror_what_it_serves
      self.serving = self.class.serving
    end

    def newly_inferring?
      return false unless inference? && archived_at.nil? && owner_subject.nil?

      previously_new_record? || saved_change_to_details? || saved_change_to_archived_at? ||
        saved_change_to_default_inference?
    end

    def summarize_what_went_without
      SummarizeUnsummarizedJob.perform_later
    end

    def checked
      through!
      yield
      true
    rescue NotImplementedError, StandardError => e
      record_check("#{e.class}: #{e.message}")
      false
    end

    def record_check(error)
      update_columns(checked_at: Time.current, check_error: error, probing_since: nil,
                     **(error.nil? ? { needs_connect_at: nil } : {}))
    end

    def next_sync_after(finished)
      anchor = next_sync_at || finished
      elapsed = ((finished - anchor) / sync_interval).floor + 1

      anchor + (elapsed * sync_interval)
    end

    def start_the_schedule
      self.next_sync_at = sync_interval.present? ? (next_sync_at || Time.current) : nil
    end

    def only_a_syncable_resource_keeps_a_schedule
      return if sync_interval.nil? || syncable?

      errors.add(:sync_interval, "cannot be set on #{self.class.sti_name}, which cannot sync")
    end

    def a_default_is_a_resource_that_can_be_one
      DEFAULTABLE.each do |capability, column|
        next unless public_send(:"#{column}?")

        next errors.add(column, "cannot be set on #{key}, which is only its owner's") if personal?
        next if capabilities.include?(capability)

        errors.add(column, "cannot be set on #{self.class.sti_name}, which is not #{capability}")
      end
    end

    def via_is_a_transport
      return if via.nil? || via.transport?

      errors.add(:via, "#{via.key} is not a transport — nothing can be reached through it")
    end

    def via_is_honored
      return if via_id.nil? || self.class.routable?

      errors.add(:via, "cannot be set on #{self.class.sti_name}, which dials its own way")
    end

    def through!
      via&.check!
    rescue StandardError => e
      raise Failed, "#{key} is reached through #{via.key}, which is down: #{e.message}"
    end

    def via_is_this_tenants
      return if via_id.nil?
      return if via.present? && via.tenant_id == tenant_id

      errors.add(:via, "belongs to another tenant, or does not exist")
    end

    def via_leads_somewhere
      return if via_id.nil?

      if via_id == id
        errors.add(:via, "cannot be itself")
        return
      end

      seen = [ id ].compact
      node = via
      hops = 0

      while node
        if seen.include?(node.id)
          errors.add(:via, "would make a loop through #{node.key}")
          return
        end

        seen << node.id
        hops += 1

        if hops > MAX_HOPS
          errors.add(:via, "is more than #{MAX_HOPS} hops from anything that answers")
          return
        end

        node = node.via
      end
    end

    def a_transport_in_use_is_not_archived
      return unless persisted? && archived_at.present? && archived_at_changed?

      dependents = Resource.active.where(via_id: id).where.not(id: id).pluck(:key)
      return if dependents.empty?

      errors.add(:archived_at,
                 "cannot be set while #{dependents.to_sentence} #{dependents.one? ? 'is' : 'are'} reached through #{key}")
    end
end
