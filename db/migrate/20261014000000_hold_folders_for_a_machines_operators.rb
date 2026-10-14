class HoldFoldersForAMachinesOperators < ActiveRecord::Migration[8.1]
  def change
    add_column :resources, :for_operators, :boolean, null: false, default: false
  end
end
