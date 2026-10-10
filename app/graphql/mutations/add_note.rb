# frozen_string_literal: true

module Mutations
  class AddNote < BaseMutation
    argument :title, String, required: false,
             description: "Left off, the first line of the note names it."
    argument :body, String, required: true

    field :feed, Types::FeedType, null: false

    def resolve(body:, title: nil)
      { feed: Intake.note!(body, title: title).feed }
    rescue Intake::Unusable, Resource::Failed => e
      refused(e.message)
    end
  end
end
