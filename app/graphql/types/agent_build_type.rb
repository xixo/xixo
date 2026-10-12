# frozen_string_literal: true

module Types
  class AgentBuildType < Types::BaseObject
    grants "xixo:resources:read"

    description "One build of the xixo agent this server hands out."

    field :os, String, null: false, description: "linux or darwin."
    field :arch, String, null: false, description: "amd64 or arm64."
    field :file, String, null: false, description: "Its name under /agent/download/."
    field :sha256, String, null: false, description: "The SHA-256 of the binary, in hex."
  end
end
