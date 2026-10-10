class AddReadersToFeeds < ActiveRecord::Migration[8.1]
  def up
    add_column :feeds, :readers, :string, array: true
    add_index :feeds, :readers, using: :gin

    select_values("SELECT id FROM tenants").each do |tenant|
      execute "SELECT set_config('#{TenantIsolation::SETTING}', #{quote(tenant.to_s)}, true)"
      execute <<~SQL
        UPDATE feeds SET readers = held.owners
        FROM (
          SELECT r.feed_id, array_agg(DISTINCT s.owner_subject ORDER BY s.owner_subject) AS owners,
                 bool_or(s.owner_subject IS NULL) AS shared
          FROM feed_references r JOIN resources s ON s.id = r.resource_id
          WHERE r.role = 'original'
          GROUP BY r.feed_id
        ) held
        WHERE feeds.id = held.feed_id AND NOT held.shared
      SQL
      4.times do
        execute <<~SQL
          UPDATE feeds SET readers = parents.readers
          FROM feeds parents
          WHERE feeds.parent_id = parents.id AND feeds.readers IS DISTINCT FROM parents.readers
        SQL
      end
    end
    execute "SELECT set_config('#{TenantIsolation::SETTING}', '', true)"
  end

  def down
    remove_column :feeds, :readers
  end
end
