# frozen_string_literal: true

module Types
  class MachineServiceType < Types::BaseObject
    grants "xixo:resources:read"

    field :kind, String, null: false, hash_key: "kind", description: "ollama or lmstudio."
    field :port, Integer, null: false, hash_key: "port"
    field :address, String, hash_key: "address", description: "The machine's tailnet address, when it is on one."
    field :url, String, hash_key: "url",
          description: "The base URL xixo reaches the model server at, over the machine's tailnet address. Empty " \
                       "for a machine on no tailnet."
    field :via, String, hash_key: "via",
          description: "The key of the tailnet xixo reaches the model server through. Empty when it has none to offer."
  end
end
