class SweepAuditEventsJob < ApplicationJob
  queue_as :sync
  across_tenants!

  def perform
    retention = Rails.configuration.xixo.audit_retention
    return if retention.zero?

    cutoff = retention.ago

    Tenant.find_each do |tenant|
      Tenant.switch(tenant) do
        AuditEvent.where(created_at: ...cutoff).in_batches(of: 1_000).delete_all
      end
    end
  end
end
