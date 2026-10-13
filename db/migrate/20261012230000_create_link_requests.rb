class CreateLinkRequests < ActiveRecord::Migration[8.1]
  include TenantIsolation

  def up
    create_table :link_requests do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :resource, foreign_key: { on_delete: :nullify }
      t.string :device_digest, null: false
      t.string :user_code, null: false
      t.string :status, null: false, default: "pending"
      t.string :hostname, null: false
      t.string :os
      t.string :arch
      t.jsonb :folders, null: false, default: []
      t.jsonb :writable, null: false, default: []
      t.string :remote_ip
      t.text :enrollment_token
      t.string :decided_by
      t.datetime :decided_at
      t.datetime :polled_at
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :device_digest, unique: true
      t.index [ :tenant_id, :user_code ], unique: true
      t.index [ :tenant_id, :expires_at ]
    end

    enable_row_level_security(:link_requests)
  end

  def down
    drop_table :link_requests
  end
end
