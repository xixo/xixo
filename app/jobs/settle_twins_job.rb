class SettleTwinsJob < ApplicationJob
  queue_as :analysis
  across_tenants!

  limits_concurrency to: 1, key: ->(*) { "digest_references" }, duration: 10.minutes

  def perform
    Tenant.find_each { |tenant| Tenant.switch(tenant) { settle } }
  end

  private

    def settle
      Reference.joinable.joins(:resource).group(:digest, "resources.owner_subject")
               .having("COUNT(DISTINCT feed_references.feed_id) > 1").pluck(Arel.sql("MIN(feed_references.id)"))
               .each { |id| Reference.find(id).settle! }
    end
end
