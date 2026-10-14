class ForgetWhatXixoMayDoWithEachMachine < ActiveRecord::Migration[8.1]
  def up
    select_values("SELECT id FROM tenants").each do |tenant|
      execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
      execute <<~SQL.squish
        UPDATE resources SET details = details - 'access', updated_at = now()
        WHERE tenant_id = #{tenant.to_i} AND type = 'machine' AND details ? 'access'
      SQL
    end
  ensure
    execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"
  end

  def down; end
end
