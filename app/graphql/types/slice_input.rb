# frozen_string_literal: true

module Types
  class SliceInput < Types::BaseInputObject
    description "A slice of the catalog: where a feed lives, how far its analysis got, what kind of file it is, " \
                "and when it was added. Every part is optional, and the parts combine."

    argument :machine_id, ID, required: false,
             description: "Only feeds with an original on this machine: in a folder it shares, or in a resource " \
                          "reached through it. This server's own id covers every resource reached directly."
    argument :resource_id, ID, required: false,
             description: "Only feeds with an original in this one resource, such as a folder a machine shares."
    argument :analysis, String, required: false,
             description: "analyzed, waiting, parked, or failed, by the feed's latest analysis. waiting covers a " \
                          "file no analysis has reached yet; parked, one waiting for a machine or a model server."
    argument :kind, String, required: false,
             description: "The kind of file, by its content type: #{MimeType.families.join(', ')}. file is everything " \
                          "the other kinds leave out."
    argument :since, GraphQL::Types::ISO8601DateTime, required: false,
             description: "Only feeds added at this moment or after it."
    argument :before, GraphQL::Types::ISO8601DateTime, required: false,
             description: "Only feeds added before this moment."
  end
end
