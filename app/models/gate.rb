class Gate < ApplicationRecord
  include TenantScoped

  Decision = Data.define(:enabled, :live) do
    def dry_run? = enabled && !live
    def closed? = !enabled
  end

  belongs_to :reference, polymorphic: true, optional: true

  validates :key, presence: true
  validate :a_reference_needs_both_halves

  scope :key_wide, -> { where(reference_type: nil, reference_id: nil) }

  def self.stopped_everywhere?
    ENV["URIS_ITERATORS_DISABLED"].present?
  end

  def self.decide(key:, reference: nil, enabled: true, live: true)
    return Decision.new(enabled: false, live: false) if stopped_everywhere?

    found = matching(key, reference).first

    return Decision.new(enabled: enabled, live: live) if found.nil?

    Decision.new(enabled: found.enabled?, live: found.live?)
  end

  def self.matching(key, reference)
    scope = where(key: key)
    return scope.key_wide if reference.nil?

    scope.where(reference: reference).or(scope.key_wide)
         .order(Arel.sql("reference_id NULLS LAST"))
  end

  def self.set!(key:, reference: nil, **attributes)
    gate = find_or_initialize_by(key: key, reference_type: reference&.class&.polymorphic_name,
                                 reference_id: reference&.id)
    gate.update!(**attributes)
    gate
  end

  private

    def a_reference_needs_both_halves
      return if reference_type.present? == reference_id.present?

      errors.add(:reference_type, "and reference_id are set together or not at all")
    end
end
