# frozen_string_literal: true

module Types
  class AttachingFieldType < Types::BaseObject
    grants "xixo:resources:read"

    field :name, String, null: false
    field :label, String, null: false
    field :kind, String, null: false, description: "string, integer, boolean, choice, or list. A list is set as one entry per line and read back as an array."
    field :required, Boolean, null: false
    field :secret, Boolean, null: false, description: "Masked here, encrypted there, never read back."
    field :value, String, description: "What it holds until something is typed."
    field :help, String
    field :placeholder, String
    field :options, [ Types::AttachingOptionType ], description: "What a choice can be."
    field :shown_when, [ Types::AttachingConditionType ],
          description: "Asked only while every one of these holds; left off, always asked."

    def shown_when
      object[:shown_when]&.map { |name, values| { field: name.to_s, values: Array(values).map(&:to_s) } }
    end
  end
end
