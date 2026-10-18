source "https://rubygems.org"

gem "rails", "~> 8.1.4"
gem "propshaft"
gem "pg", "~> 1.7"
gem "puma", ">= 5.0"
gem "graphql"

gem "mcp"


masks_client = ENV["MASKS_CLIENT_PATH"].to_s

if File.file?(File.join(masks_client, "masks.gemspec"))
  gem "masks", path: masks_client
elsif Bundler.default_gemfile.basename.to_s == "Gemfile.local"
  gem "masks", path: "../masks/client"
else
  gem "masks", "~> 0.12"
end

masks_server = ENV["MASKS_SERVER_PATH"].to_s

if File.file?(File.join(masks_server, "masks-server.gemspec"))
  gem "masks-server", path: masks_server, require: false
else
  gem "masks-server", "~> 0.9", require: false
end

gem "vite_rails"

gem "opensearch-ruby"

gem "aws-sdk-s3", require: false
gem "net-imap", require: false
gem "nokogiri"

gem "ferrum"

gem "ruby-vips", require: false

gem "job-iteration"

gem "json", "~> 2.21"

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
  gem "jwt"
  gem "webmock"
end
