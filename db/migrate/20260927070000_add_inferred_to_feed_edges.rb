class AddInferredToFeedEdges < ActiveRecord::Migration[8.1]
  def up
    add_column :feed_edges, :inferred, :boolean, default: false, null: false
  end

  def down
    remove_column :feed_edges, :inferred
  end
end
