# frozen_string_literal: true

module Types
  class DetailType < Types::BaseObject
    grants "xixo:catalog:read"

    field :group, String, null: false,
          description: "The heading it is shown under, named for the step that produced it, such as Embedded in the file or Document."
    field :step, String, null: false,
          description: "The name of the analysis step it was read from."
    field :item, Integer,
          description: "Which record it belongs to, counting from 1, when the step found several, such as attachments or events."
    field :label, String, null: false,
          description: "What the value is, in words, such as Lens ID or Page size."
    field :value, String, null: false,
          description: "The value as text, cut to 400 characters."
  end
end
