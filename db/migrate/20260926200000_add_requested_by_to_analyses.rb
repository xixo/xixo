class AddRequestedByToAnalyses < ActiveRecord::Migration[8.1]
  def change
    add_column :analyses, :requested_by, :string
  end
end
