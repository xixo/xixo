# frozen_string_literal: true

module Types
  class SetupClientType < Types::BaseObject
    field :name, String, null: false,
          description: "The client's id, as it named itself to masks."
    field :person, String,
          description: "The person it acted for. Empty for a client that acted as itself."
    field :at, GraphQL::Types::ISO8601DateTime, null: false, method: :created_at,
          description: "When it last called a tool."

    def name
      (object.actor == "person" ? object.via : object.actor_name).presence || "an unnamed client"
    end

    def person
      object.actor_name if object.actor == "person"
    end
  end
end
