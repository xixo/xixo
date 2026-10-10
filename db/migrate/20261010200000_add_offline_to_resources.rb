class AddOfflineToResources < ActiveRecord::Migration[8.1]
  def change
    add_column :resources, :offline_host, :string
    add_column :resources, :offline_last_seen_at, :datetime
  end
end
