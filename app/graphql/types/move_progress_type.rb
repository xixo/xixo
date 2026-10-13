# frozen_string_literal: true

module Types
  class MoveProgressType < Types::BaseObject
    grants "xixo:catalog:read"

    description "How far a move has come."

    field :files, Integer, null: false, description: "The files the move found to carry."
    field :files_done, Integer, null: false, description: "The files that now live at the destination."
    field :files_failed, Integer, null: false, description: "The files that stayed where they were. The run's log names each one."
    field :bytes, GraphQL::Types::BigInt, null: false, description: "The size of every file the move found, in bytes."
    field :bytes_done, GraphQL::Types::BigInt, null: false, description: "The size of the files already moved, in bytes."
  end
end
