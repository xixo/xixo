# frozen_string_literal: true

module Types
  class ServerImageType < Types::BaseObject
    grants "xixo:settings:read"

    description "An image the updater keeps up to date: xixo, xixo-link, or masks."

    field :name, String, null: false, hash_key: "name", description: "xixo, xixo-link, or masks."
    field :current, String, hash_key: "current", description: "The digest of the build it runs."
    field :previous, String, hash_key: "previous", description: "The digest of the build a rollback goes back to."
    field :created, String, hash_key: "created", description: "When CI built the current build."
    field :revision, String, hash_key: "revision", description: "The commit the current build came from."
    field :version, String, hash_key: "version", description: "The version or branch the current build names."
    field :target, String, description: "The digest of the newest build on the channel, when it differs from the current one."
    field :containers, [ Types::ServerContainerType ], null: false, description: "The containers that run it."

    def target
      held = object["target"]
      held unless held == object["current"]
    end

    def containers = Array(object["containers"]).select { |held| held.is_a?(Hash) }
  end
end
