class RenameToXixo < ActiveRecord::Migration[8.1]
  include TenantIsolation

  INDEX = "index_feeds_on_one_row_per_address".freeze
  CURRENT_TENANT = "NULLIF(current_setting('#{TenantIsolation::SETTING}', true), '')::bigint".freeze

  def up
    isolated = select_values("SELECT tablename FROM pg_policies WHERE schemaname = 'public' AND policyname = 'tenant_isolation'")
    isolated.each do |table|
      execute "DROP POLICY tenant_isolation ON #{quote_table_name(table)}"
      enable_row_level_security(quote_table_name(table))
    end

    select_values(<<~SQL).each { |table| change_column_default table, :tenant_id, -> { CURRENT_TENANT } }
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'tenant_id' AND column_default LIKE '%current_setting%'
    SQL

    remove_index :feeds, name: INDEX
    select_values("SELECT id FROM tenants").each do |tenant|
      execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
      execute "UPDATE feeds SET type = 'xixo:' || split_part(type, ':', 2) WHERE type NOT LIKE 'xixo:%'"
    end
    execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"
    add_index :feeds, %i[tenant_id type key], unique: true, name: INDEX,
              where: "type IN ('xixo:tag', 'xixo:address', 'xixo:mime')"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
