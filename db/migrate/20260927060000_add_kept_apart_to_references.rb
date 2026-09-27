class AddKeptApartToReferences < ActiveRecord::Migration[8.1]
  def up
    add_column :feed_references, :kept_apart, :boolean, default: false, null: false

    SettleTwinsJob.perform_later
  end

  def down
    remove_column :feed_references, :kept_apart
  end
end
