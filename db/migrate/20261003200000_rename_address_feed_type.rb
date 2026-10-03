class RenameAddressFeedType < ActiveRecord::Migration[8.1]
  INDEX = "index_feeds_on_one_row_per_address".freeze

  def up
    retype("uris:feed", "uris:address")
  end

  def down
    retype("uris:address", "uris:feed")
  end

  private

    def retype(from, to)
      remove_index :feeds, name: INDEX

      select_values("SELECT id FROM tenants").each do |tenant|
        execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
        execute "UPDATE feeds SET type = #{quote(to)} WHERE type = #{quote(from)}"
      end
      execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"

      add_index :feeds, %i[tenant_id type key], unique: true, name: INDEX,
                where: "type IN ('uris:tag', #{quote(to)}, 'uris:mime')"
    end
end
