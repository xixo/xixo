# frozen_string_literal: true

module Types
  class PlanLineType < Types::BaseObject
    grants "xixo:resources:read"

    description "One thing a machine does, as xixo plans it from the machine's description. The plan has a line " \
                "for catalog, extract, and models."

    field :key, String, null: false, hash_key: "key", description: "catalog, extract, or models."
    field :says, String, null: false, hash_key: "says", description: "The line in plain words, such as \"Catalog Documents and Books.\""
    field :why, String, hash_key: "why", description: "Why xixo plans it so, or what keeps it from happening."
    field :on, Boolean, null: false, hash_key: "on", description: "Whether the machine does it. An administrator turns a line off."
    field :possible, Boolean, null: false, hash_key: "possible",
          description: "Whether the machine can do it at all. A line that is not possible cannot be turned on."
  end
end
