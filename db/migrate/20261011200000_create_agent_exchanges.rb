class CreateAgentExchanges < ActiveRecord::Migration[8.1]
  include TenantIsolation

  def up
    create_table :agent_exchanges do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :resource, null: false, foreign_key: { on_delete: :cascade }
      t.references :parent, foreign_key: { to_table: :agent_exchanges, on_delete: :cascade }
      t.uuid :request, null: false
      t.string :verb, null: false
      t.string :status, null: false, default: "asked"
      t.jsonb :result
      t.string :error
      t.bigint :received, null: false, default: 0
      t.datetime :answered_at
      t.timestamps

      t.index :request, unique: true
      t.index [ :tenant_id, :created_at ]
    end

    create_table :agent_chunks do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :agent_exchange, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :seq, null: false
      t.binary :bytes, null: false
      t.datetime :created_at, null: false

      t.index [ :agent_exchange_id, :seq ], unique: true
    end

    enable_row_level_security(:agent_exchanges)
    enable_row_level_security(:agent_chunks)
  end

  def down
    drop_table :agent_chunks
    drop_table :agent_exchanges
  end
end
