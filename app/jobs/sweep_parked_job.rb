class SweepParkedJob < ApplicationJob
  queue_as :sync
  across_tenants!

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { ResumeParkedJob.perform_later if Analysis.parked.exists? }
    end
  end
end
