class NullifyAnalysisReferenceOnDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :analyses, :feed_references, column: :reference_id
    add_foreign_key :analyses, :feed_references, column: :reference_id, on_delete: :nullify
  end
end
