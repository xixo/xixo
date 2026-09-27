class IndexStagedDigests < ActiveRecord::Migration[8.1]
  def change
    add_index :active_storage_blobs, "((metadata::jsonb ->> 'digest'))",
              where: "(metadata::jsonb ->> 'digest') IS NOT NULL",
              name: "index_active_storage_blobs_on_digest"
  end
end
