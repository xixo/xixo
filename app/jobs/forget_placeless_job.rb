class ForgetPlacelessJob < ApplicationJob
  queue_as :sync

  BATCH = 1_000

  def self.enqueue(ids, cause:)
    ids.each_slice(BATCH) { |held| perform_later(held, cause) }
  end

  def perform(ids, cause)
    Feed.placeless(ids).find_each do |feed|
      title = feed.title || feed.key
      feed.destroy!

      AuditEvent.record(
        channel: "job", action: "forget_placeless_feed", status: "ok",
        grant: nil, context: { remote_ip: nil, request_id: nil },
        told: "forgot #{title}, whose last place went with #{cause}",
        arguments: { "title" => title, "cause" => cause }
      )
    end

    Feed.reindex!(Feed.where(id: ids).to_a)
  end
end
