class AddDetailsToLinkRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :link_requests, :details, :jsonb, null: false, default: {}
  end
end
