# frozen_string_literal: true

module Types
  class AttachingFieldType < Types::BaseObject
    grants "xixo:resources:read"

    field :name, String, null: false
    field :label, String, null: false
    field :kind, String, null: false, description: "string, integer, boolean, choice, list, lines, or text. A list is set as entries split on " \
                                                       "whitespace and a lines field as one entry per line, and both are read back as arrays. " \
                                                       "A text field holds several lines as they are."
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
