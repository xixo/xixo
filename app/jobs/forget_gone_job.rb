class ForgetGoneJob < ApplicationJob
  queue_as :sync
  across_tenants!

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { forget_gone }
    end
  end

  private

    def forget_gone
      Feed.long_gone.find_each do |feed|
        title = feed.title || feed.key
        places = feed.references.originals.count
        feed.destroy!

        AuditEvent.record(
          channel: "job", action: "forget_gone_feed", status: "ok",
          grant: nil, context: { remote_ip: nil, request_id: nil },
          told: "forgot #{title}, gone from every place it lived for #{Feed::GONE_FOR.inspect}",
          arguments: { "title" => title, "places" => places }
        )
      end
    end
end
