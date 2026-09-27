# frozen_string_literal: true

module Mutations
  class CancelAnalysis < BaseMutation
    argument :id, ID, required: true

    field :analysis, Types::AnalysisType, null: false
    field :cancelled, Boolean, null: false

    def resolve(id:)
      analysis = Analysis.find_by(id: id) || raise(GraphQL::ExecutionError, "no analysis with id #{id}")

      { cancelled: analysis.cancel!, analysis: analysis.reload }
    end
  end
end
