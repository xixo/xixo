# frozen_string_literal: true

module Types
  class MachineServiceType < Types::BaseObject
    grants "xixo:resources:read"

    field :kind, String, null: false, hash_key: "kind", description: "ollama or lmstudio."
    field :port, Integer, null: false, hash_key: "port"
    field :address, String, hash_key: "address", description: "The machine's tailnet address, when it is on one."
    field :local_only, Boolean, null: false,
          description: "Whether the model server answers only on the machine itself, so xixo cannot reach it over the network."
    field :url, String, hash_key: "url",
          description: "The base URL to add the model server at. A server that answers only on its machine is reached " \
                       "through xixo link at 127.0.0.1. Empty when xixo cannot reach it."
    field :via, String, hash_key: "via",
          description: "The key of the tailnet or machine xixo reaches the model server through. Empty when it has none to offer."

    def local_only = object["local_only"] == true
  end
end
