require_relative "../../lib/tenancy/job"

ActiveSupport.on_load(:active_job) { include Tenancy::Job }

Rails.application.config.to_prepare { SolidQueue::RecurringJob.across_tenants! }
