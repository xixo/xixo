# frozen_string_literal: true

module Types
  class LinkUpType < Types::BaseObject
    grants "xixo:resources:read"

    description "What a machine needs to install xixo link itself and link up."

    field :xixo, String, null: false, description: "The address xixo link dials."
    field :issuer, String, null: false, description: "The masks issuer xixo link enrolls with."
    field :builds, [ Types::LinkBuildType ], null: false,
          description: "The xixo link builds this server hands out, by system and architecture."
    field :mac_reader, String,
          description: "Where a Mac gets the mac reader: the asset of the GitHub release of this server's version, " \
                       "with its SHA-256 beside it at the same address ending .sha256. Empty when the server's " \
                       "version is unknown."
  end
end
