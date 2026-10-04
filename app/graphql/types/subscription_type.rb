# frozen_string_literal: true

module Types
  class SubscriptionType < Types::BaseObject
    field :feed_analyzed, subscription: Subscriptions::FeedAnalyzed, grants: "xixo:catalog:read"
    field :analysis_progressed, subscription: Subscriptions::AnalysisProgressed,
          grants: "xixo:catalog:read"
    field :run_progressed, subscription: Subscriptions::RunProgressed, grants: "xixo:catalog:read"
  end
end
