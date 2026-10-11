class EmbedItemsJob < ApplicationJob
  BUDGET = 50.seconds

  queue_as :analysis
  across_tenants!

  limits_concurrency to: 1, key: "embed_items", duration: 5.minutes

  def perform(budget: BUDGET)
    deadline = budget.from_now
    waiting = Tenant.pluck(:id)

    until waiting.empty? || Time.current > deadline
      waiting = waiting.select { |id| swept(id).positive? }
    end
  end

  private

    def swept(id)
      tenant = Tenant.find_by(id: id)
      return 0 if tenant.nil?

      Tenant.switch(tenant) { Embedding.sweep! + Passage.sweep! }
    rescue Resource::Failed => e
      Rails.logger.warn("#{tenant.subdomain} embedded nothing: #{e.class}: #{e.message.truncate(200)}")
      0
    end
end
