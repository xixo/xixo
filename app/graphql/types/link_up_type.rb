# frozen_string_literal: true

module Types
  class LinkUpType < Types::BaseObject
    grants "xixo:resources:read"

    description "What the command that links up a machine needs."

    field :xixo, String, null: false,
          description: "The address of this xixo. The command is curl -fsSL <xixo>/link.sh | sh, followed by the " \
                       "folders the machine shares."
    field :systems, [ String ], null: false,
          description: "The systems this server holds a build of xixo link for: linux, darwin, or both."
  end
end
