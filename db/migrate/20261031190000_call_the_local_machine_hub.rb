class CallTheLocalMachineHub < ActiveRecord::Migration[8.1]
  def up
    each_tenant { |tenant| rename(tenant, from: "This server", to: "Hub") }
  end

  def down
    each_tenant { |tenant| rename(tenant, from: "Hub", to: "This server") }
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

    def rename(tenant, from:, to:)
      execute <<~SQL.squish
        UPDATE resources SET name = #{quote(to)}, updated_at = now()
        WHERE tenant_id = #{tenant.to_i} AND type = 'machine' AND key = 'local' AND name = #{quote(from)}
      SQL
    end
end
