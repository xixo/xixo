class ParkAnalysesThatWaitForAMachine < ActiveRecord::Migration[8.1]
  def change
    add_column :analyses, :waits_for, :string
    add_reference :analyses, :waits_on, foreign_key: { to_table: :resources, on_delete: :nullify }, index: false
    add_index :analyses, %i[tenant_id waits_on_id], where: "status = 'parked'", name: "index_analyses_parked"
  end
end
