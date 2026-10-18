# frozen_string_literal: true

module Types
  class MachinePartType < Types::BaseObject
    grants "xixo:resources:read"

    description "A part xixo link runs on the machine, such as models, which runs Ollama."

    field :name, String, null: false, hash_key: "name", description: "models."
    field :version, String, hash_key: "version", description: "The version of the program the part runs."
    field :state, String, null: false, hash_key: "state",
          description: "missing, fetching, starting, running, failed, or stopped."
    field :port, Integer, hash_key: "port", description: "The port the part answers on, once it runs."
    field :warning, String, hash_key: "warning", description: "What went wrong, as a sentence, when the part failed."
    field :pulls, [ Types::MachinePullType ], null: false, hash_key: "pulls",
          description: "Each model the part pulls, with its progress."
  end
end
