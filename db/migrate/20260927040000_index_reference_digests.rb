class IndexReferenceDigests < ActiveRecord::Migration[8.1]
  def change
    add_index :feed_references, %i[tenant_id digest], where: "digest IS NOT NULL",
              name: "index_feed_references_on_tenant_id_and_digest"
  end
end
