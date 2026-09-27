module Embedding
  ROLE = "embedding".freeze
  MAX_TEXT = 8_000
  BODY_TEXT = 2_000
  BATCH = 50
  QUERY_HELD = 1.day

  class << self
    def dimensions
      SearchIndex::VECTOR_DIMENSIONS
    end

    def held
      Resource.for_declared_role(ROLE)
    end

    def gist(feed)
      [
        feed.title,
        feed.keywords.join(", ").presence,
        feed.summaries.join("\n").presence,
        feed.note,
        feed.body_text(without: [ :summary ])&.truncate(BODY_TEXT)
      ].compact_blank.join("\n").strip.truncate(MAX_TEXT)
    end

    def digest_of(text, model)
      Digest::SHA256.hexdigest([ model, text ].join("\n")).first(32)
    end

    def query(text, resource: held)
      return nil if resource.nil? || text.blank?

      wanted = text.to_s.truncate(MAX_TEXT)

      Rails.cache.fetch(query_key(resource, wanted), expires_in: QUERY_HELD) do
        resource.embed([ wanted ]).first
      end
    rescue Resource::Failed
      nil
    end

    def sweep!(limit: BATCH)
      resource = held
      return 0 if resource.nil?

      items = Feed.unembedded.includes(:analyses, children: :analyses).limit(limit).to_a
      return 0 if items.empty?

      items.each { |item| Passage.cut!(item) }

      model = resource.model_for(ROLE)
      wanted = items.to_h { |item| [ item.id, gist(item) ] }
      digests = wanted.transform_values { |text| digest_of(text, model) }
      moved, settled = items.partition { |item| item.embedded_digest != digests.fetch(item.id) }

      settle(settled)
      write!(resource, moved, wanted, digests)

      items.length
    end

    private

      def settle(items)
        return if items.empty?

        Feed.where(id: items.map(&:id)).update_all(embedded_at: Time.current)
      end

      def write!(resource, items, wanted, digests)
        return if items.empty?

        vectors = resource.embed(items.map { |item| wanted.fetch(item.id) })

        items.each_with_index do |item, index|
          item.update_columns(
            embedding: vectors.fetch(index),
            embedded_digest: digests.fetch(item.id),
            embedded_at: Time.current
          )
        end

        SearchIndex.index_all(items)
      end

      def query_key(resource, text)
        [ "embedding", Current.tenant&.id, resource.id, resource.model_for(ROLE),
          Digest::SHA256.hexdigest(text).first(32) ].join("/")
      end
  end
end
