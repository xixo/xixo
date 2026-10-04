# frozen_string_literal: true

module Mutations
  class ForgetFeed < BaseMutation
    argument :id, ID, required: true

    field :forgotten, Boolean, null: false
    field :places, Integer, null: false,
          description: "How many places it lived that xixo stopped pointing at."

    def resolve(id:)
      feed = feed!(id)
      title = feed.title
      places = feed.references.originals.count

      feed.destroy!

      noted(title, places)

      { forgotten: true, places: places }
    end

    private

      def noted(title, places)
        AuditEvent.record(
          channel: "graphql", action: "forget_feed", status: "ok",
          grant: context[:grant], context: Current.audit,
          told: "forgot #{title || 'a feed'}, which lived in #{places} #{'place'.pluralize(places)}",
          arguments: { "title" => title, "places" => places }
        )
      end
  end
end
