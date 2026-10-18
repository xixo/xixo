# frozen_string_literal: true

module Types
  class MachineServiceType < Types::BaseObject
    grants "xixo:resources:read"

    description "A model server xixo link found listening on the machine. When the machine's plan runs models, " \
                "xixo attaches it through the machine by itself."

    field :kind, String, null: false, hash_key: "kind", description: "ollama or lmstudio."
    field :port, Integer, null: false, hash_key: "port"
  end
end
