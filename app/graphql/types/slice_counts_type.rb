# frozen_string_literal: true

module Types
  class SliceCountsType < Types::BaseObject
    description "How many feeds each choice of a slice would list, counted with the rest of the slice applied, " \
                "so a count is what picking that choice shows."

    field :where, [ Types::SliceCountType ], null: false, hash_key: :where,
          description: "By the resource an original lives in, most first. Resources this token cannot reach are left out."
    field :analysis, [ Types::SliceCountType ], null: false, hash_key: :analysis,
          description: "By analysis state: analyzed, waiting, parked, failed."
    field :kind, [ Types::SliceCountType ], null: false, hash_key: :kind,
          description: "By kind of file."
    field :when, [ Types::SliceCountType ], null: false, hash_key: :when,
          description: "Added in the past day, week, month, and year."
  end
end
