# frozen_string_literal: true

module Types
  class DiscoveredServiceType < Types::BaseObject
    grants "xixo:resources:read"

    description "A well-known port that answered on a node a transport reaches."

    field :name, String, null: false, description: "What usually listens on the port, such as ollama."
    field :port, Integer, null: false
    field :type, String, null: false, description: "The type of resource that reaches it."
    field :address, String, null: false, description: "What that type's address field would hold to reach it."
  end
end
