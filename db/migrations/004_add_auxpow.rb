Sequel.migration do
  change do
    create_table(:raw_aux_pows) do
      primary_key :id
      column :block_hsh, :text, null: false
      column :payload, :bytea
      
      index [:block_hsh], unique: true
    end
    
    alter_table(:addresses) do
      # bigint can be overflowed for very large addresses in the case of Dogecoin
      set_column_type :total_received, :numeric, :size=>20
      set_column_type :total_sent, :numeric, :size=>20
    end
  end
end
