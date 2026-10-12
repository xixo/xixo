class ForgetLinkExchangesJob < ApplicationJob
  queue_as :sync
  across_tenants!

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { LinkExchange.stale.in_batches(of: 500).destroy_all }
    end
  end
end
