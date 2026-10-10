require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false

  config.eager_load = true

  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true

  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  config.active_storage.service = ENV.fetch("XIXO_STAGING_SERVICE", "local").to_sym

  config.assume_ssl = Switch.on?("RAILS_ASSUME_SSL", default: true)

  config.force_ssl = Switch.on?("RAILS_FORCE_SSL", default: true)

  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  config.silence_healthcheck_path = "/up"

  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store

  config.i18n.fallbacks = true

  config.active_record.dump_schema_after_migration = false

  config.active_record.attributes_for_inspect = [ :id ]

  if ENV["XIXO_PUBLIC_ORIGIN"].blank? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
    raise "XIXO_PUBLIC_ORIGIN is not set. Production names the token audience and every link from it, " \
          "so without it the request's Host header would choose."
  end

  if ENV["SECRET_KEY_BASE_DUMMY"].blank?
    published = %w[SECRET_KEY_BASE ENCRYPTION_PRIMARY_KEY ENCRYPTION_DETERMINISTIC_KEY ENCRYPTION_KEY_DERIVATION_SALT]
                .select { |name| ENV[name].blank? || ENV[name].start_with?("dev_only_") }

    if published.any?
      raise "#{published.to_sentence} #{published.one? ? 'is' : 'are'} unset or a published development value. " \
            "Anyone with the repository could forge sessions or read encrypted credentials, so generate " \
            "your own as the self-hosting guide describes."
    end
  end

  if ENV["XIXO_HOST_SUFFIX"].present?
    config.hosts << ".#{ENV['XIXO_HOST_SUFFIX']}"
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end
end
