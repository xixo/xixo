# frozen_string_literal: true

module Types
  class ServerContainerType < Types::BaseObject
    grants "xixo:settings:read"

    description "A container on this server that the updater keeps up to date."

    field :name, String, null: false, hash_key: "name", description: "The container's name in Docker."
    field :service, String, hash_key: "service", description: "The compose service it runs, such as xixo or worker."
    field :state, String, null: false, hash_key: "state", description: "running, exited, or restarting, as Docker reports it."
    field :health, String, hash_key: "health", description: "healthy, unhealthy, or starting, when the container has a health check."
    field :stale, Boolean, null: false, description: "Whether it still runs a build other than the current one."

    def stale = object["stale"] == true
  end
end
