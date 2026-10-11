# frozen_string_literal: true

module Sources
  class ItemsCount < GraphQL::Dataloader::Source
    def fetch(resource_ids)
      counts = Reference.where(resource_id: resource_ids).group(:resource_id).distinct.count(:feed_id)

      resource_ids.map { |id| counts.fetch(id, 0) }
    end
  end
end
