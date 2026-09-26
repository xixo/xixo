namespace :docs do
  desc "Write the reference pages under docs/ from the code they describe, and check the ENV vars page against it"
  task reference: :environment do
    [
      ReferencePages::Graphql,
      ReferencePages::Mcp,
      ReferencePages::Resources,
      ReferencePages::Scopes
    ].each do |page|
      puts "wrote #{page.write.relative_path_from(Rails.root)}"
    end

    drift = ReferencePages::Environment.new.drift
    abort drift.join("\n") if drift.any?

    puts "checked #{ReferencePages::Environment::PAGE}"
  end
end
