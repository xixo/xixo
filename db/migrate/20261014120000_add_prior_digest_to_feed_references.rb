class AddPriorDigestToFeedReferences < ActiveRecord::Migration[8.1]
  def change
    add_column :feed_references, :prior_digest, :string
  end
end
