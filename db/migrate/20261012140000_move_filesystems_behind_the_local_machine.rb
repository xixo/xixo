class MoveFilesystemsBehindTheLocalMachine < ActiveRecord::Migration[8.1]
  LOCAL = "local".freeze
  DEFAULT_ROOT = "/data/files".freeze

  def up
    select_rows("SELECT id, subdomain FROM tenants").each do |tenant, subdomain|
      execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
      move(tenant, subdomain)
    end
  ensure
    execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    def move(tenant, subdomain)
      execute "UPDATE resources SET type = 'filesystem' WHERE tenant_id = #{tenant.to_i} AND type = 'agent-folder'"

      direct = select_rows(<<~SQL.squish)
        SELECT id, details FROM resources
        WHERE tenant_id = #{tenant.to_i} AND type = 'filesystem' AND via_id IS NULL
      SQL
      return if direct.empty?

      local = local_machine(tenant)

      direct.each do |id, details|
        held = details.is_a?(String) ? JSON.parse(details) : details.to_h
        moved = held.except("root").merge("folder" => folder_for(held, subdomain))

        execute <<~SQL.squish
          UPDATE resources SET via_id = #{local.to_i}, details = #{quote(moved.to_json)}::jsonb, updated_at = now()
          WHERE id = #{id.to_i}
        SQL
      end
    end

    def folder_for(held, subdomain)
      root = held["root"].to_s
      return Pathname.new(root).cleanpath.to_s if root.start_with?("/")

      (Pathname.new(old_root) + subdomain.to_s + root).cleanpath.to_s
    end

    def old_root
      ENV.fetch("XIXO_FILESYSTEM_ROOTS", "").split(":").map(&:strip).find(&:present?) || DEFAULT_ROOT
    end

    def local_machine(tenant)
      held = select_value(<<~SQL.squish)
        SELECT id FROM resources WHERE tenant_id = #{tenant.to_i} AND type = 'machine' AND key = #{quote(LOCAL)}
      SQL
      return held if held

      select_value(<<~SQL.squish)
        INSERT INTO resources (tenant_id, type, key, name, details, serving, created_at, updated_at)
        VALUES (#{tenant.to_i}, 'machine', #{quote(LOCAL)}, 'This server', '{"local": true}'::jsonb,
                '{"capabilities": ["transport"], "accepts": []}'::jsonb, now(), now())
        RETURNING id
      SQL
    end
end
