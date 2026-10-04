class Passage < ApplicationRecord
  SIZE = 1_500
  OVERLAP = 200
  BREAKS = [ "\n\n", "\n", ". ", "? ", "! ", "; ", ", ", " " ].freeze
  SEEK_BACK = 0.4
  BATCH = 64
  CUTS = 50
  LEAD_IN = 200

  include TenantScoped

  belongs_to :feed

  scope :unembedded, -> { where(embedded_at: nil) }

  class << self
    def split(text)
      body = text.to_s
      return [] if body.length <= SIZE

      spans = []
      start = 0

      while start < body.length
        finish = cut_point(body, start)
        spans << [ start, finish ]
        break if finish >= body.length

        start = resume_point(body, [ finish - OVERLAP, start + 1 ].max)
      end

      spans
    end

    def cut!(feed)
      body = feed.readable_text.to_s
      digest = Digest::SHA256.hexdigest(body).first(32)
      return false if feed.passages_digest == digest

      spans = split(body)

      transaction do
        where(feed_id: feed.id).delete_all
        now = Time.current
        rows = spans.each_with_index.map do |(start, finish), position|
          { tenant_id: feed.tenant_id, feed_id: feed.id, position: position, starts_at: start, ends_at: finish,
            text: body[start...finish], created_at: now, updated_at: now }
        end
        insert_all!(rows) if rows.any?
        Feed.where(id: feed.id).update_all(passages_digest: digest)
      end

      PassageIndex.delete_for(feed)
      true
    end

    def sweep!(limit: CUTS)
      Feed.where(passages_digest: nil).includes(:analyses, children: :analyses).limit(limit).each { |feed| cut!(feed) }

      embed!
    end

    def embed!(limit: BATCH)
      resource = Embedding.held
      return 0 if resource.nil?

      held = unembedded.includes(:feed).order(:id).limit(limit).to_a
      return 0 if held.empty?

      vectors = resource.embed(held.map(&:embedded_text))

      held.each_with_index do |passage, index|
        passage.update_columns(embedding: vectors.fetch(index), embedded_at: Time.current)
      end

      PassageIndex.index_all(held)
      held.size
    end

    private

      def cut_point(body, start)
        limit = start + SIZE
        return body.length if limit >= body.length

        floor = start + (SIZE * (1 - SEEK_BACK)).to_i

        BREAKS.each do |mark|
          at = body.rindex(mark, limit - mark.length)
          return at + mark.length if at && at >= floor
        end

        limit
      end

      def resume_point(body, at)
        space = body.index(/\s/, at)
        return at if space.nil? || space - at > LEAD_IN

        space + 1
      end
  end

  def embedded_text
    [ feed.title, text ].compact_blank.join("\n")
  end
end
