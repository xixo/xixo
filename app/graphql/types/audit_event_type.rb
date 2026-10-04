# frozen_string_literal: true

module Types
  class AuditEventType < Types::BaseObject
    grants "xixo:catalog:read"

    field :id, ID, null: false
    field :actor, String, null: false,
          description: "Who asked: person, client, agent, or nobody."
    field :actor_name, String,
          description: "The person's name or the client's id. Agents and nobody have none."
    field :via, String,
          description: "The client a person asked through."
    field :told, String,
          description: "What was asked, in one sentence, written when it was asked."
    field :feed, Types::FeedType,
          description: "The feed it was about, while that feed still exists."
    field :analysis, Types::AnalysisType,
          description: "The analysis whose agent asked, when an agent did."
    field :working_on, Types::FeedType,
          description: "The feed that agent was analyzing."
    field :channel, String, null: false
    field :action, String, null: false
    field :status, String, null: false
    field :scope, String
    field :remote_ip, String
    field :request_id, String
    field :duration_ms, Integer
    field :detail, String
    field :arguments, GraphQL::Types::JSON, null: false
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false

    def working_on
      object.analysis&.feed
    end
  end
end
