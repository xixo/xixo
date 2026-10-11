# frozen_string_literal: true

module Types
  class MachineServiceType < Types::BaseObject
    grants "xixo:resources:read"

    field :kind, String, null: false, hash_key: "kind", description: "ollama or lmstudio."
    field :port, Integer, null: false, hash_key: "port"
    field :address, String, hash_key: "address", description: "The machine's tailnet address, when it is on one."
  end
end
