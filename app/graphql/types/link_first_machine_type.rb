# frozen_string_literal: true

module Types
  class LinkFirstMachineType < Types::BaseObject
    grants "xixo:settings:read"

    description "The machine a rollout updates first on one platform."

    field :os, String, null: false, hash_key: "os", description: "linux or darwin."
    field :resource, Types::ResourceType, description: "The machine. Empty when no machine on the platform could go first."
    field :arrived_at, String, hash_key: "arrived_at", description: "When it connected on the release, once it has."
    field :picked, Boolean, null: false, hash_key: "picked", description: "Whether an administrator chose it, instead of xixo."

    def resource
      Resource::Machine.active.find_by(id: object["id"]) if object["id"]
    end
  end
end
