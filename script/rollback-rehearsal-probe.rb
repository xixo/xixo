sql = Rails.root.join("db/structure.sql").read
connection = ActiveRecord::Base.connection
missing = []

sql.scan(/^CREATE TABLE public\.("?\w+"?) \(\n(.*?)^\);/m) do |table, body|
  table = table.delete('"')
  unless connection.table_exists?(table)
    missing << table
    next
  end

  present = connection.columns(table).map(&:name)
  body.each_line do |line|
    line = line.strip.delete_suffix(",")
    next if line.empty? || line.start_with?("CONSTRAINT")

    column = line.split(" ", 2).first.delete('"')
    missing << "#{table}.#{column}" unless present.include?(column)
  end
end

if missing.any?
  abort "The last release has #{missing.join(', ')}, which this build removed. " \
        "A release removes a table or column one release after the last one that read it."
end

puts "Every table and column the last release has is still there."
