class AddAdministeredAtToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :administered_at, :datetime
  end
end
