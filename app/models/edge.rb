class Edge < ApplicationRecord
  self.table_name = "feed_edges"

  include TenantScoped

  belongs_to :a, class_name: "Feed"
  belongs_to :b, class_name: "Feed"

  validates :a_id, uniqueness: { scope: [ :tenant_id, :b_id ] }
  validate :the_pair_is_canonical

  scope :touching, ->(id) { where(a_id: id).or(where(b_id: id)) }
  scope :inferred, -> { where(inferred: true) }

  def self.pair(one, other)
    [ one, other ].map { |held| held.respond_to?(:id) ? held.id : held.to_i }.sort
  end

  def self.between(one, other)
    low, high = pair(one, other)

    find_by(a_id: low, b_id: high)
  end

  def self.between!(one, other, inferred: false)
    low, high = pair(one, other)
    raise ArgumentError, "a feed cannot connect to itself" if low == high

    edge = create_with(inferred: inferred).find_or_create_by!(a_id: low, b_id: high)
    edge.update!(inferred: false) if edge.inferred && !inferred
    edge
  end

  def other_than(feed)
    held = feed.respond_to?(:id) ? feed.id : feed.to_i

    held == a_id ? b : a
  end

  private

    def the_pair_is_canonical
      return if a_id.blank? || b_id.blank?
      return if a_id < b_id

      errors.add(:a_id, a_id == b_id ? "cannot connect a feed to itself" : "is not the lower half")
    end
end
