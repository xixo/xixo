class RetagFeedsJob < ApplicationJob
  queue_as :default
  across_tenants!

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { AnalyzeFeedsJob.perform_later(tenant.id, { "type" => [ Feed::FILE, Feed::NOTE ] }) }
    end
  end
end
