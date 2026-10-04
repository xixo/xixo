class Holdings
  KINDS = 8
  TAGS = 10
  COUNTED = { Feed::FILE => "file", Feed::NOTE => "note", Feed::ADDRESS => "address" }.freeze

  def self.said
    new.said
  end

  def said
    return "It is empty." if total.zero?

    [
      "It holds #{counted}.",
      ("By kind, the files are #{listed(majors)}." if majors.any?),
      ("The most common kinds of file are #{listed(kinds)}." if kinds.any?),
      ("The tags most used are #{listed(tags)}." if tags.any?)
    ].compact.join(" ")
  end

  def counts
    @counts ||= Feed.where(type: COUNTED.keys).group(:type).count
  end

  def kinds
    @kinds ||= Reference.originals.where(feed_id: Feed.files.select(:id)).where.not(mime: nil)
                        .group(:mime).count.max_by(KINDS) { |_mime, count| count }
  end

  def majors
    @majors ||= Reference.originals.where(feed_id: Feed.files.select(:id)).where.not(mime: nil)
                         .group(Arel.sql("split_part(mime, '/', 1)")).count.sort_by { |_kind, count| -count }
  end

  def tags
    @tags ||= begin
      held = Feed.tags.pluck(:id, :key).to_h
      used = Edge.where(a_id: held.keys).group(:a_id).count
                 .merge(Edge.where(b_id: held.keys).group(:b_id).count) { |_id, one, other| one + other }

      used.max_by(TAGS) { |_id, count| count }.map { |id, count| [ held[id], count ] }
    end
  end

  private

    def total
      counts.values.sum
    end

    def counted
      COUNTED.filter_map do |type, noun|
        held = counts[type].to_i
        "#{held} #{noun.pluralize(held)}" if held.positive?
      end.to_sentence
    end

    def listed(pairs)
      pairs.map { |name, count| "#{name} (#{count})" }.join(", ")
    end
end
