require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

require_relative "../lib/tenancy/middleware"
require_relative "../lib/switch"

Switch.check!

module Uris
  class Application < Rails::Application
    config.active_record.query_log_tags_enabled = true
    config.active_record.query_log_tags = [
      :application, :controller, :action, :job,
      current_graphql_operation: -> { GraphQL::Current.operation_name },
      current_graphql_field: -> { GraphQL::Current.field&.path },
      current_dataloader_source: -> { GraphQL::Current.dataloader_source_class }
    ]
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks tenancy switch.rb])

    config.middleware.use Tenancy::Middleware

    config.active_record.schema_format = :sql

    config.active_storage.variant_processor = :disabled
    config.active_storage.draw_routes = false
    config.active_storage.analyzers = []
    config.active_storage.previewers = []

    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }

    config.uris = ActiveSupport::OrderedOptions.new
    config.uris.tenant = ENV["URIS_TENANT"].presence
    config.uris.tenants = ENV["URIS_TENANTS"].to_s.split(/[\s,]+/).reject(&:empty?)
    config.uris.mcp_limit = ENV.fetch("URIS_MCP_LIMIT", 120).to_i
    config.uris.run_budget = ENV.fetch("URIS_RUN_BUDGET", 20).to_i
    config.uris.audit_retention = ENV.fetch("URIS_AUDIT_RETENTION_DAYS", 90).to_i.days
    config.uris.run_retention = ENV.fetch("URIS_RUN_RETENTION_DAYS", 14).to_i.days
    config.uris.run_deadline = ENV.fetch("URIS_RUN_DEADLINE_HOURS", 6).to_i.hours

    config.active_record.encryption.primary_key = ENV["ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key = ENV["ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["ENCRYPTION_KEY_DERIVATION_SALT"]

    if ENV["PG_BIN_PATH"].present?
      ENV["PATH"] = "#{ENV['PG_BIN_PATH']}:#{ENV['PATH']}"
    end
  end
end
