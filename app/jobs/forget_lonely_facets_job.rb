class ForgetLonelyFacetsJob < ApplicationJob
  queue_as :sync
  across_tenants!

  def perform
    Tenant.find_each { |tenant| Tenant.switch(tenant) { Feed.forget_lonely! } }
  end
end
