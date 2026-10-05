class Setting < ApplicationRecord
  include TenantScoped

  class Unknown < StandardError; end

  LEVELS = %i[personal shared server].freeze

  Definition = Data.define(:key, :level, :default, :allowed, :label, :note, :unit) do
    def personal? = level == :personal
    def server? = level == :server
    def permits?(value) = allowed.include?(value)
    def reads = server? ? "xixo:settings:admin" : "xixo:settings:read"
    def writes = server? ? "xixo:settings:admin" : "xixo:settings:write"
  end

  DEFINED = [
    Definition.new(
      key: "catalog_view",
      level: :personal,
      default: "list",
      allowed: %w[list cards],
      label: "How the catalog opens",
      note: "A list reads names quickly. Cards show you what an item looks like.",
      unit: nil
    ),
    Definition.new(
      key: "thumbnail_size",
      level: :shared,
      default: "320",
      allowed: %w[160 240 320 480 640],
      label: "Thumbnail width",
      note: "The width in pixels of the small image rendered for every photo, video, PDF, and page " \
            "capture. Items rendered before a change keep their old size until they are analyzed again.",
      unit: "px"
    ),
    Definition.new(
      key: "hires_size",
      level: :shared,
      default: "1500",
      allowed: %w[1024 1500 2048 3072],
      label: "Hi-res size",
      note: "The longest edge in pixels of the large image a thumbnail opens, which is also what the " \
            "vision model reads. A page capture keeps its full length at this width.",
      unit: "px"
    ),
    Definition.new(
      key: "animation_frames",
      level: :shared,
      default: "4",
      allowed: %w[1 2 4 6 8 12],
      label: "Most frames read from an animation",
      note: "How many frames of a GIF, WebP, or APNG the vision model is shown at most, spread evenly " \
            "across it. More frames describe more of what happens, and each one adds to how long it takes.",
      unit: nil
    ),
    Definition.new(
      key: "animation_frame_share",
      level: :shared,
      default: "100",
      allowed: %w[10 25 50 100],
      label: "Share of an animation's frames read",
      note: "The percentage of an animation's frames the vision model is shown, rounded up and never " \
            "more than the most frames read. A short animation is read in full and a long one is sampled.",
      unit: "%"
    )
  ].index_by(&:key).freeze

  validates :key, inclusion: { in: DEFINED.keys }
  validate :value_is_one_the_definition_allows

  def self.definition!(key)
    DEFINED[key.to_s] || raise(Unknown, "no setting named #{key}")
  end

  def self.at(level)
    DEFINED.values.select { |definition| definition.level == level }
  end

  def self.read(key, subject:)
    definition = definition!(key)

    owned(definition, subject).find_by(key: definition.key)&.value || definition.default
  end

  def self.write!(key, value, subject:)
    definition = definition!(key)
    record = owned(definition, subject).find_or_initialize_by(key: definition.key)

    record.update!(value: value)
    record
  end

  def self.owned(definition, subject)
    where(subject: definition.personal? ? subject : nil)
  end

  def definition
    DEFINED[key]
  end

  private

    def value_is_one_the_definition_allows
      return if definition.nil? || definition.permits?(value)

      errors.add(:value, "is not one of #{definition.allowed.join(', ')}")
    end
end
