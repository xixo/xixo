# frozen_string_literal: true

module Types
  class ScheduleType < Types::BaseObject
    grants "xixo:catalog:read"

    field :id, ID, null: false
    field :prompt, String, null: false
    field :turns, Integer
    field :interval, Integer, description: "Seconds between runs. Null when it only runs by hand."
    field :next_run_at, GraphQL::Types::ISO8601DateTime
    field :paused_at, GraphQL::Types::ISO8601DateTime
    field :ran_at, GraphQL::Types::ISO8601DateTime
    field :scheduled, Boolean, null: false

    def scheduled = object.scheduled?
  end
end
