class NameTheProgramOnEachMachineXixoLink < ActiveRecord::Migration[8.1]
  def up
    rename_table :agent_exchanges, :link_exchanges
    rename_table :agent_chunks, :link_chunks
    rename_column :link_chunks, :agent_exchange_id, :link_exchange_id

    each_tenant { |tenant| retype(tenant, from: "xixo-agent", to: "machine") }
  end

  def down
    each_tenant { |tenant| retype(tenant, from: "machine", to: "xixo-agent") }

    rename_column :link_chunks, :link_exchange_id, :agent_exchange_id
    rename_table :link_chunks, :agent_chunks
    rename_table :link_exchanges, :agent_exchanges
  end

  private

    def each_tenant
      select_values("SELECT id FROM tenants").each do |tenant|
        execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
        yield tenant
      end
    ensure
      execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"
    end

    def retype(tenant, from:, to:)
      execute <<~SQL.squish
        UPDATE resources SET type = #{quote(to)}, updated_at = now()
        WHERE tenant_id = #{tenant.to_i} AND type = #{quote(from)}
      SQL
    end
end
