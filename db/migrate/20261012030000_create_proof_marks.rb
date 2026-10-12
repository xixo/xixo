class CreateProofMarks < ActiveRecord::Migration[8.1]
  def change
    create_table :proof_marks, id: false do |t|
      t.string :digest, null: false, primary_key: true
      t.datetime :expires_at, null: false
    end

    add_index :proof_marks, :expires_at
  end
end
