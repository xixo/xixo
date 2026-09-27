class CreatePassages < ActiveRecord::Migration[8.1]
  include TenantIsolation

  def up
    create_table :passages do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :feed, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false
      t.integer :starts_at, null: false
      t.integer :ends_at, null: false
      t.text :text, null: false
      t.float :embedding, array: true
      t.datetime :embedded_at
      t.timestamps

      t.index [ :tenant_id, :feed_id, :position ], unique: true
      t.index [ :tenant_id, :embedded_at ]
    end

    enable_row_level_security(:passages)

    add_column :feeds, :passages_digest, :string
  end

  def down
    remove_column :feeds, :passages_digest
    drop_table :passages
  end
end
