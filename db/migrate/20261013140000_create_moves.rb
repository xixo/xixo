class CreateMoves < ActiveRecord::Migration[8.1]
  include TenantIsolation

  def up
    add_column :link_exchanges, :expected, :bigint
    add_column :link_exchanges, :sent, :bigint, null: false, default: 0
    add_column :link_exchanges, :sent_seq, :integer, null: false, default: 0

    create_table :moves do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :run, null: false, foreign_key: { on_delete: :cascade }
      t.references :source, null: false, foreign_key: { to_table: :resources, on_delete: :cascade }
      t.references :destination, null: false, foreign_key: { to_table: :resources, on_delete: :cascade }
      t.references :feed, foreign_key: { on_delete: :nullify }
      t.string :path, null: false
      t.string :target, null: false
      t.bigint :size, null: false
      t.datetime :modified_at
      t.string :status, null: false, default: "waiting"
      t.string :sha256
      t.string :error
      t.timestamps

      t.index [ :run_id, :source_id, :path ], unique: true
      t.index [ :run_id, :status ]
    end

    enable_row_level_security(:moves)
  end

  def down
    drop_table :moves
    remove_column :link_exchanges, :sent_seq
    remove_column :link_exchanges, :sent
    remove_column :link_exchanges, :expected
  end
end
