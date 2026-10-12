# frozen_string_literal: true

module Types
  class LinkUpType < Types::BaseObject
    grants "xixo:resources:read"

    description "What a machine needs to install the xixo agent itself and link up."

    field :xixo, String, null: false, description: "The address the agent dials."
    field :issuer, String, null: false, description: "The masks issuer the agent enrolls with."
    field :builds, [ Types::AgentBuildType ], null: false,
          description: "The agent builds this server hands out, by system and architecture."
  end
end
