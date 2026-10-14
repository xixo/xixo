class Page
  DEFAULT = 50
  MAX = 200

  attr_reader :nodes, :has_more

  def self.of(scope, after: nil, limit: nil)
    size = (limit || DEFAULT).to_i.clamp(1, MAX)
    counted = scope.except(:includes, :preload, :eager_load, :order)
    scope = scope.reorder(id: :desc)
    scope = scope.where(id: ...after.to_i) if after.present?

    rows = scope.limit(size + 1).to_a

    new(rows.first(size), rows.size > size, nil, -> { after.blank? && rows.size <= size ? rows.size : counted.count })
  end

  def self.at(nodes, from:, total:)
    reached = from + nodes.length

    new(nodes, reached < total, reached.to_s, total)
  end

  def initialize(nodes, has_more, cursor = nil, total = nil)
    @nodes = nodes
    @has_more = has_more
    @cursor = cursor
    @total = total
  end

  def total
    @total = @total.call if @total.respond_to?(:call)
    @total
  end

  def next_cursor
    return nil unless has_more

    @cursor || nodes.last&.id&.to_s
  end
end
