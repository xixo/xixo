# frozen_string_literal: true

module Types
  class MachinePullType < Types::BaseObject
    grants "xixo:resources:read"

    field :model, String, null: false, hash_key: "model"
    field :done, GraphQL::Types::BigInt, null: false, hash_key: "done", description: "Bytes pulled so far."
    field :total, GraphQL::Types::BigInt, null: false, hash_key: "total", description: "Bytes in all. Zero until the server says."
    field :ready, Boolean, null: false, hash_key: "ready", description: "Whether the model is on the machine."
    field :error, String, hash_key: "error", description: "Why the pull failed, when it did."
  end
end
