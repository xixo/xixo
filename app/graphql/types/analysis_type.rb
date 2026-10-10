# frozen_string_literal: true

module Types
  class AnalysisType < Types::BaseObject
    grants "xixo:catalog:read"

    field :id, ID, null: false
    field :cause, String, null: false
    field :status, String, null: false
    field :steps, GraphQL::Types::JSON, null: false
    field :turns, GraphQL::Types::JSON, null: false
    field :lines, Integer, null: false
    field :logs, String,
          description: "Everything the pass has logged so far, newest last."
    field :error, String
    field :started_at, GraphQL::Types::ISO8601DateTime
    field :finished_at, GraphQL::Types::ISO8601DateTime
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :duration_ms, Integer
    field :deadline, GraphQL::Types::ISO8601DateTime,
          description: "When it is cut off. It moves out when the agent asks for more time, never past a day from its start."
    field :said, String, description: "What the agent answered when the pass finished, if it ran."
    field :drew_on, [ Types::FeedType ], null: false,
          description: "What this answer cited, opened or kept, each connected to the note it answers."
    field :question, String,
          description: "What this pass was asked, when it answers a question: the note's first question, or a follow-up."

    def drew_on
      ids = Array(object.step_result("drew_on")).map(&:to_i)
      found = Feed.readable_by(context[:grant]).where(id: ids).index_by(&:id)

      ids.filter_map { |id| found[id] }
    end

    def question
      return nil unless object.cause == "ask"

      object.question.presence || object.feed.key || object.feed.title
    end

    def said
      object.step_result("answer").to_h["said"].presence || last_agent_word
    end

    def last_agent_word
      spoken = object.turns.select { |turn| turn["role"] == "agent" && turn["calls"].blank? }

      spoken.last&.dig("content").presence
    end
  end
end
