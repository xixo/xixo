# frozen_string_literal: true

module Types
  class LinkRequestType < Types::BaseObject
    grants "xixo:resources:read"

    description "A machine asking to link up. xixo link on the machine started it and shows its code. Only an " \
                "administrator approves or denies it, and it runs out after ten minutes."

    field :id, ID, null: false
    field :code, String, null: false, description: "The code the machine shows, such as WDJB-MJHT.", method: :user_code
    field :status, String, null: false,
          description: "pending, approved, handed (the machine took its enrollment token), linked, or denied."
    field :hostname, String, null: false, description: "The name the machine gives itself."
    field :os, String
    field :arch, String
    field :folders, [ String ], null: false, description: "The folders the machine's config shares."
    field :writable, [ String ], null: false, description: "The shared folders the machine marks writable."
    field :remote_ip, String, description: "The address the request came from."
    field :expires_at, GraphQL::Types::ISO8601DateTime, null: false
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :machine, Types::ResourceType, description: "The machine it linked up as, once it has.", method: :resource
  end
end
