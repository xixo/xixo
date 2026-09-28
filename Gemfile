source "https://rubygems.org"

gem "rails", "~> 8.1.4"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "graphql"

gem "mcp"

gem "jwt"

masks_client = ENV["MASKS_CLIENT_PATH"].to_s

if File.file?(File.join(masks_client, "masks.gemspec"))
  gem "masks", path: masks_client
elsif Bundler.default_gemfile.basename.to_s == "Gemfile.local"
  gem "masks", path: "../masks/client"
else
  gem "masks", "~> 0.7"
end

gem "vite_rails"

gem "opensearch-ruby"

gem "aws-sdk-s3", require: false
gem "net-imap", require: false
gem "nokogiri"

gem "ferrum"

gem "job-iteration"

gem "csv"
gem "json", "~> 2.21"

gem "roo"
gem "rubyzip", require: "zip"
gem "mail"

gem "tzinfo-data", platforms: %i[ windows jruby ]

gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "bootsnap", require: false

gem "thruster", require: false

group :development, :test do
  gem "dotenv-rails"

  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "bundler-audit", require: false

  gem "brakeman", require: false

  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"

  gem "graphiql-rails"
end

gem "mission_control-jobs"

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "webmock"
end
