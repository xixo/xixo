module PassageIndex
  MAPPING = {
    dynamic: false,
    properties: {
      tenant_id: { type: "long" },
      feed_id: { type: "long" },
      readers: { type: "keyword" },
      starts_at: { type: "integer" },
      ends_at: { type: "integer" },
      text: { type: "text" },
      embedding: {
        type: "knn_vector",
        dimension: SearchIndex::VECTOR_DIMENSIONS,
        method: { name: "hnsw", engine: "lucene", space_type: "cosinesimil" }
      }
    }
  }.freeze

  Hit = Data.define(:feed_id, :starts_at, :ends_at, :text, :score)

  STAMP = Digest::SHA256.hexdigest(MAPPING.to_json).first(12).freeze
  FILL_BATCH = 500

  class << self
    def name
      "#{prefix}_#{STAMP}"
    end

    def prefix
      "#{SearchIndex.alias_name}_passages"
    end

    def filled?
      client.indices.get_mapping(index: name).dig(name, "mappings", "_meta", "filled") == true
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      false
    end

    def fill!
      create!

      Tenant.find_each do |tenant|
        Tenant.switch(tenant) do
          Passage.where.not(embedded_at: nil).includes(:feed).find_in_batches(batch_size: FILL_BATCH) do |batch|
            index_all(batch)
          end
        end
      end

      client.indices.put_mapping(index: name, body: { _meta: { filled: true } })
      stale.each { |held| client.indices.delete(index: held, ignore: 404) }
    end

    def stale
      client.indices.get(index: "#{prefix}*").keys - [ name ]
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      []
    end

    def client
      SearchIndex.client
    end

    def create!
      return name if client.indices.exists(index: name)

      client.indices.create(index: name, body: { settings: { index: { knn: true } }, mappings: MAPPING })
      name
    rescue OpenSearch::Transport::Transport::Errors::BadRequest => e
      raise unless e.message.include?("resource_already_exists_exception")

      name
    end

    def index_all(passages)
      passages = passages.to_a.select { |passage| passage.embedding.present? }
      return 0 if passages.empty?

      create!
      body = passages.flat_map do |passage|
        [ { index: { _index: name, _id: passage.id } },
          { tenant_id: passage.tenant_id, feed_id: passage.feed_id, readers: readers_of(passage),
            starts_at: passage.starts_at,
            ends_at: passage.ends_at, text: passage.text, embedding: passage.embedding } ]
      end

      response = client.bulk(body: body)
      refused = Array(response["items"]).filter_map { |item| item.dig("index", "error") }
      raise SearchIndex::Failed, "#{refused.length} passages were refused: #{refused.first['reason']}" if refused.any?

      passages.size
    end

    def delete_for(feed)
      client.delete_by_query(
        index: name, conflicts: "proceed",
        body: { query: { bool: { must: [ { term: { tenant_id: feed.tenant_id } }, { term: { feed_id: feed.id } } ] } } }
      )
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      nil
    end

    def nearest(vector, tenant:, limit:, reader: Current.grant&.speaks_for, feed_id: nil)
      return [] if vector.blank? || tenant.nil?

      filters = [ { term: { tenant_id: tenant.id } }, SearchIndex.readable(reader) ]
      filters << { term: { feed_id: feed_id } } if feed_id

      response = client.search(
        index: name,
        body: {
          query: { knn: { embedding: { vector: vector, k: limit, filter: { bool: { must: filters } } } } },
          size: limit, _source: %w[feed_id starts_at ends_at text embedding]
        }
      )

      close(vector, response.dig("hits", "hits"))
    rescue OpenSearch::Transport::Transport::Errors::NotFound,
           OpenSearch::Transport::Transport::Errors::BadRequest => e
      Rails.logger.warn("the search engine refused a passage query: #{e.message.truncate(200)}")
      []
    end

    def refresh!
      client.indices.refresh(index: name)
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      nil
    end

    def reset!
      client.indices.delete(index: name, ignore: 404)
      create!
    end

    private

      def readers_of(passage)
        passage.feed&.readers.presence || [ SearchIndex::EVERYONE ]
      end

      def close(vector, hits)
        scored = Array(hits).map do |hit|
          held = hit["_source"]
          Hit.new(feed_id: held["feed_id"], starts_at: held["starts_at"], ends_at: held["ends_at"],
                  text: held["text"], score: SearchIndex.cosine(vector, held["embedding"]))
        end.sort_by { |hit| -hit.score }

        bar = [ SearchIndex::SEMANTIC_FLOOR, scored.first&.score.to_f - SearchIndex::SEMANTIC_MARGIN ].max
        scored.take_while { |hit| hit.score >= bar }
      end
  end
end
