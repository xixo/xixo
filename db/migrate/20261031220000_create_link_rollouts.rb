class CreateLinkRollouts < ActiveRecord::Migration[8.1]
  include TenantIsolation

  def up
    create_table :link_rollouts do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :release, null: false
      t.string :version
      t.bigint :serial
      t.integer :protocol
      t.string :phase, null: false, default: "waiting_for_server"
      t.jsonb :first_machines, null: false, default: {}
      t.datetime :started_at, null: false
      t.datetime :phase_at, null: false
      t.text :held_reason
      t.timestamps

      t.index [ :tenant_id, :release ], unique: true
      t.index [ :tenant_id, :started_at ]
    end

    enable_row_level_security(:link_rollouts)
  end

  def down
    drop_table :link_rollouts
  end
end
