class AddProbingSinceToResources < ActiveRecord::Migration[8.1]
  def up
    add_column :resources, :probing_since, :datetime
  end

  def down
    remove_column :resources, :probing_since
  end
end
