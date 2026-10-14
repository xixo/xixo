class SettleReadersJob < ApplicationJob
  queue_as :default

  def perform(resource_ids)
    Feed.where(id: Reference.originals.where(resource_id: Array(resource_ids)).select(:feed_id))
        .find_each(&:settle_readers!)
  end
end
