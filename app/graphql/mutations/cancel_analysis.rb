# frozen_string_literal: true

module Mutations
  class CancelAnalysis < BaseMutation
    argument :id, ID, required: true, description: "The analysis to stop. It can be queued or running."

    field :analysis, Types::AnalysisType, null: false, description: "The analysis after the call."
    field :cancelled, Boolean, null: false,
          description: "True when the analysis was open and is now cancelled. False when it had already finished."

    def resolve(id:)
      analysis = Analysis.find_by(id: id) || raise(GraphQL::ExecutionError, "no analysis with id #{id}")

      { cancelled: analysis.cancel!, analysis: analysis }
    end
  end
end
