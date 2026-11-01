%w[db:prepare db:migrate].each do |name|
  Rake::Task[name].enhance { SchemaRelease.record! }
end
