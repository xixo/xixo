# frozen_string_literal: true

module Types
  class RunType < Types::BaseObject
    grants "xixo:catalog:read"

    field :id, ID, null: false
    field :kind, String, null: false
    field :status, String, null: false
    field :selector, GraphQL::Types::JSON, null: false
    field :processed, Integer, null: false
    field :lines, Integer, null: false,
          description: "How many log lines this run has written."
    field :logs, String,
          description: "Everything the run has logged so far, newest last."
    field :error, String
    field :started_at, GraphQL::Types::ISO8601DateTime
    field :finished_at, GraphQL::Types::ISO8601DateTime
    field :deadline, GraphQL::Types::ISO8601DateTime
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :resource, Types::ResourceType
  end
end
