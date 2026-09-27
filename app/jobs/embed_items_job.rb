class EmbedItemsJob < ApplicationJob
  queue_as :analysis
  across_tenants!

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { sweep(tenant) }
    end
  end

  private

    def sweep(tenant)
      Embedding.sweep!
      Passage.sweep!
    rescue Resource::Failed => e
      Rails.logger.warn("#{tenant.subdomain} embedded nothing: #{e.class}: #{e.message.truncate(200)}")
    end
end
