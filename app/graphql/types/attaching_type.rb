# frozen_string_literal: true

module Types
  class AttachingType < Types::BaseObject
    grants "xixo:resources:read"

    description "What one type of resource needs before it can answer."

    field :type, String, null: false
    field :label, String, null: false
    field :blurb, String, null: false
    field :names, String, null: false, description: "What the key means for this type."
    field :capabilities, [ String ], null: false
    field :syncs, Boolean, null: false
    field :delegated, Boolean, null: false,
          description: "Connected through masks with somebody's own account, rather than by typing a credential."
    field :routable, Boolean, null: false,
          description: "Whether it can be reached through a transport, such as a tailnet."
    field :addressed_by, String,
          description: "The field that holds the address it is reached at, for a type a transport can reach."
    field :fields, [ Types::AttachingFieldType ], null: false
  end
end
