class LinkRolloutJob < ApplicationJob
  queue_as :sync
  across_tenants!
  limits_concurrency to: 1, key: "link_rollout", on_conflict: :discard

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { LinkRollout.tend! }
    rescue StandardError => e
      Rails.logger.warn("LinkRolloutJob: #{tenant.subdomain}: #{e.class}: #{e.message}")
    end
  end
end
