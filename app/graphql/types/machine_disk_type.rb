# frozen_string_literal: true

module Types
  class MachineDiskType < Types::BaseObject
    grants "xixo:resources:read"

    field :path, String, null: false, hash_key: "path"
    field :total, GraphQL::Types::BigInt, hash_key: "total"
    field :free, GraphQL::Types::BigInt, hash_key: "free"
  end
end
