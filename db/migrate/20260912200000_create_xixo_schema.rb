class CreateXixoSchema < ActiveRecord::Migration[8.1]
  include TenantIsolation

  CURRENT_TENANT = -> { "NULLIF(current_setting('#{TenantIsolation::SETTING}', true), '')::bigint" }

  ISOLATED = %w[
    resources
    resource_blobs
    feeds
    feed_references
    feed_edges
    analyses
    schedules
    runs
    audit_events
    gates
    settings
    active_storage_blobs
    active_storage_attachments
    active_storage_variant_records
  ].freeze

  def up
    create_table :tenants do |t|
      t.string :subdomain, null: false
      t.string :name, null: false
      t.timestamps
      t.string :client_id
      t.text :client_secret
      t.text :registration_access_token
      t.string :registration_client_uri
      t.datetime :connected_at

      t.index :subdomain, unique: true
    end

    create_table :resources do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :type, null: false
      t.string :key, null: false
      t.string :name
      t.jsonb :details, null: false, default: {}
      t.text :credentials
      t.datetime :archived_at
      t.timestamps
      t.integer :sync_interval
      t.datetime :next_sync_at
      t.datetime :sync_started_at
      t.datetime :synced_at
      t.datetime :checked_at
      t.string :check_error
      t.boolean :default_storage, null: false, default: false
      t.boolean :default_inference, null: false, default: false
      t.bigint :via_id
      t.jsonb :serving, null: false, default: {}

      t.index [ :tenant_id, :type, :key ], unique: true
      t.index [ :id, :tenant_id ], unique: true
      t.index :tenant_id, unique: true, where: "default_storage",
                          name: "index_resources_on_one_default_storage_per_tenant"
      t.index :tenant_id, unique: true, where: "default_inference",
                          name: "index_resources_on_one_default_inference_per_tenant"
      t.index [ :tenant_id, :next_sync_at ], where: "sync_interval IS NOT NULL",
                                             name: "index_resources_on_sync_due"
      t.index [ :tenant_id, :via_id ], where: "via_id IS NOT NULL", name: "index_resources_on_via"
      t.index :serving, using: :gin
    end

    execute <<~SQL
      ALTER TABLE resources
        ADD CONSTRAINT fk_resources_via
        FOREIGN KEY (via_id, tenant_id) REFERENCES resources (id, tenant_id)
        ON DELETE RESTRICT
    SQL

    create_table :resource_blobs do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :resource, null: false, foreign_key: true
      t.string :key, null: false
      t.string :content_type
      t.binary :bytes, null: false
      t.timestamps

      t.index [ :tenant_id, :resource_id, :key ], unique: true
    end

    create_table :feeds do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :type, null: false
      t.string :key, null: false
      t.string :title
      t.text :note
      t.references :parent, foreign_key: { to_table: :feeds }
      t.string :origin, null: false, default: "resource"
      t.column :embedding, "double precision[]"
      t.string :embedded_digest
      t.datetime :embedded_at
      t.timestamps

      t.index [ :tenant_id, :type, :key ], unique: true,
                                           where: "type IN ('xixo:tag', 'xixo:feed', 'xixo:mime')",
                                           name: "index_feeds_on_one_row_per_address"
      t.index [ :tenant_id, :type ]
      t.index [ :tenant_id, :key ]
      t.index [ :tenant_id, :created_at ]
      t.index [ :tenant_id, :origin ]
      t.index [ :tenant_id, :parent_id ]
      t.index [ :tenant_id, :id ], where: "embedded_at IS NULL", name: "index_feeds_awaiting_a_vector"
    end

    create_table :feed_references do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :feed, null: false, foreign_key: true
      t.references :resource, null: false, foreign_key: true
      t.string :role, null: false, default: "original"
      t.jsonb :locator, null: false, default: {}
      t.string :locator_key
      t.string :mime
      t.bigint :size
      t.string :digest
      t.string :version
      t.string :source_version
      t.datetime :changed_at
      t.datetime :analyzed_at
      t.timestamps

      t.index [ :tenant_id, :resource_id, :locator_key ], unique: true,
                                                          where: "locator_key IS NOT NULL",
                                                          name: "index_feed_references_on_locator"
      t.index [ :tenant_id, :feed_id, :role ]
      t.index [ :tenant_id, :analyzed_at ]
    end

    create_table :feed_edges do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :a, null: false, foreign_key: { to_table: :feeds }
      t.references :b, null: false, foreign_key: { to_table: :feeds }
      t.timestamps

      t.index [ :tenant_id, :a_id, :b_id ], unique: true
      t.index [ :tenant_id, :b_id ]
      t.check_constraint "a_id < b_id", name: "feed_edges_are_canonical"
    end

    create_table :analyses do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :feed, null: false, foreign_key: true
      t.references :reference, foreign_key: { to_table: :feed_references }
      t.string :cause, null: false
      t.string :status, null: false, default: "queued"
      t.jsonb :steps, null: false, default: {}
      t.jsonb :turns, null: false, default: []
      t.text :logs
      t.integer :lines, null: false, default: 0
      t.string :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :deadline
      t.timestamps

      t.index [ :tenant_id, :feed_id, :id ]
      t.index [ :tenant_id, :status ]
      t.index [ :tenant_id, :finished_at ]
    end

    create_table :schedules do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :feed, null: false, foreign_key: true
      t.text :prompt, null: false
      t.integer :turns
      t.integer :interval
      t.datetime :paused_at
      t.datetime :next_run_at
      t.datetime :ran_at
      t.timestamps

      t.index [ :tenant_id, :feed_id ], unique: true
      t.index [ :tenant_id, :next_run_at ], where: "next_run_at IS NOT NULL AND paused_at IS NULL"
    end

    create_table :runs do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :resource, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.jsonb :selector, null: false, default: {}
      t.integer :processed, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :deadline
      t.string :error
      t.timestamps
      t.text :logs
      t.integer :lines, null: false, default: 0

      t.index [ :tenant_id, :kind, :id ]
      t.index [ :tenant_id, :status, :id ]
      t.index "tenant_id, (selector->>'id')", name: "index_runs_on_tenant_and_selector_id"
    end

    create_table :audit_events do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :run, foreign_key: true
      t.string :channel, null: false
      t.string :action, null: false
      t.string :status, null: false
      t.string :scope
      t.string :subject
      t.string :client_id
      t.string :remote_ip
      t.string :request_id
      t.integer :duration_ms
      t.string :detail
      t.jsonb :arguments, null: false, default: {}
      t.datetime :created_at, null: false

      t.index [ :tenant_id, :id ]
      t.index [ :tenant_id, :action, :id ]
      t.index [ :tenant_id, :status, :id ]
    end

    create_table :gates do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :key, null: false
      t.string :reference_type
      t.bigint :reference_id
      t.boolean :enabled, null: false, default: true
      t.boolean :live, null: false, default: true
      t.string :note
      t.timestamps

      t.index [ :tenant_id, :key, :reference_type, :reference_id ],
              unique: true, nulls_not_distinct: true, name: "index_gates_on_scope"
    end

    create_table :settings do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :subject
      t.string :key, null: false
      t.jsonb :value
      t.timestamps

      t.index [ :tenant_id, :subject, :key ],
              unique: true, nulls_not_distinct: true, name: "index_settings_on_scope"
    end

    create_table :active_storage_blobs do |t|
      t.references :tenant, null: false, foreign_key: true, default: CURRENT_TENANT
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, null: false

      t.index :key, unique: true
    end

    create_table :active_storage_attachments do |t|
      t.references :tenant, null: false, foreign_key: true, default: CURRENT_TENANT
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }
      t.datetime :created_at, null: false

      t.index [ :record_type, :record_id, :name, :blob_id ],
              name: :index_active_storage_attachments_uniqueness, unique: true
    end

    create_table :active_storage_variant_records do |t|
      t.references :tenant, null: false, foreign_key: true, default: CURRENT_TENANT
      t.belongs_to :blob, null: false, index: false, foreign_key: { to_table: :active_storage_blobs }
      t.string :variation_digest, null: false

      t.index [ :blob_id, :variation_digest ],
              name: :index_active_storage_variant_records_uniqueness, unique: true
    end

    ISOLATED.each { |table| enable_row_level_security(table) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
