class AddAboutToAnalyses < ActiveRecord::Migration[8.1]
  def change
    add_reference :analyses, :about, foreign_key: { to_table: :feeds, on_delete: :nullify }
  end
end
