class IndexFeedReferencesByMime < ActiveRecord::Migration[8.1]
  def change
    add_index :feed_references, [ :tenant_id, :mime ], opclass: { mime: :varchar_pattern_ops },
              name: "index_feed_references_on_tenant_id_and_mime"
  end
end
