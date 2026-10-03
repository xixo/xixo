# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    field :tenant, Types::TenantType, null: true, grants: "uris:catalog:read"

    def tenant
      context[:tenant]
    end

    field :settings, [ Types::SettingType ], null: false, grants: "uris:settings:read"

    def settings
      grant = context[:grant]
      subject = grant.subject

      Setting::LEVELS.flat_map { |level| Setting.at(level) }
                     .select { |definition| grant.permits?(definition.reads) }
                     .map do |definition|
        definition.to_h.merge(value: Setting.read(definition.key, subject: subject))
      end
    end

    field :feed, Types::FeedType, null: true, grants: "uris:catalog:read" do
      argument :id, ID, required: false
      argument :key, String, required: false, description: "An address, as /buy."
    end

    def feed(id: nil, key: nil)
      return Feed.find_by(id: id) if id.present?

      Feed.address(key) if key.present?
    end

    field :feeds, Types::FeedPageType, null: false, grants: "uris:catalog:read" do
      argument :type, String, required: false
      argument :types, [ String ], required: false, description: "Any of these types, instead of one."
      argument :mime, String, required: false
      argument :resource_id, ID, required: false
      argument :tag, String, required: false,
               description: "A tag key, for everything connected to it."
      argument :connected_to, ID, required: false
      argument :top_level, Boolean, required: false,
               description: "Only what was not extracted from something else."
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def feeds(type: nil, types: nil, mime: nil, resource_id: nil, tag: nil, connected_to: nil,
              top_level: false, after: nil, limit: nil)
      scope = Feed.matching({ type: types.presence || type, mime: mime, resource_id: resource_id,
                              tag: tag }.compact)
      scope = scope.where(parent_id: nil) if top_level
      scope = scope.where(id: Feed.connected_to(Feed.find(connected_to)).select(:id)) if connected_to.present?

      Page.of(scope, after: after, limit: limit)
    end

    field :search, Types::FeedPageType, null: false, grants: "uris:catalog:read" do
      argument :query, String, required: false
      argument :type, String, required: false
      argument :types, [ String ], required: false, description: "Any of these types, instead of one."
      argument :after, ID, required: false,
               description: "How far into the matches to start. A search is walked by offset."
      argument :limit, Integer, required: false
    end

    def search(query: nil, type: nil, types: nil, after: nil, limit: nil)
      Feed.found(query, type: types.presence || type, from: after.to_i,
                        limit: (limit || Page::DEFAULT).to_i.clamp(1, Page::MAX))
    end

    field :types, [ Types::TypeCountType ], null: false, grants: "uris:catalog:read"

    def types
      Feed.where(parent_id: nil).group(:type).order(count_all: :desc).count.map do |type, count|
        { type: type, count: count }
      end
    end

    field :resources, [ Types::ResourceType ], null: false, grants: "uris:resources:read" do
      argument :archived, Boolean, required: false,
               description: "Left off, the ones still in use. True, the ones put away."
    end

    def resources(archived: false)
      scope = archived ? Resource.attended.reachable_by(context[:grant]).where.not(archived_at: nil) : Resource.visible_to(context[:grant])

      scope.order(:type, :key)
    end

    field :resource_types, [ Types::AttachingType ], null: false, grants: "uris:resources:read",
          description: "Every type that can be attached, and what each of them needs."

    def resource_types
      Resource.attachable.map do |klass|
        klass.attaching.merge(
          type: klass.sti_name,
          capabilities: klass.capabilities.map(&:to_s),
          syncs: klass.method_defined?(:each_page),
          delegated: klass.delegated?,
          routable: klass.routable?
        )
      end
    end

    field :run, Types::RunType, null: true, grants: "uris:catalog:read" do
      argument :id, ID, required: true
    end

    def run(id:)
      Run.visible_to(context[:grant]).find_by(id: id)
    end

    field :runs, Types::RunPageType, null: false, grants: "uris:catalog:read" do
      argument :kind, String, required: false
      argument :status, String, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def runs(kind: nil, status: nil, after: nil, limit: nil)
      scope = Run.visible_to(context[:grant])
      scope = scope.where(kind: kind) if kind.present?
      scope = scope.where(status: status) if status.present?

      Page.of(scope, after: after, limit: limit)
    end

    field :analysis, Types::AnalysisType, null: true, grants: "uris:catalog:read" do
      argument :id, ID, required: true
    end

    def analysis(id:)
      Analysis.find_by(id: id)
    end

    field :analyses, Types::AnalysisPageType, null: false, grants: "uris:catalog:read" do
      argument :feed_id, ID, required: false
      argument :status, String, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def analyses(feed_id: nil, status: nil, after: nil, limit: nil)
      scope = Analysis.all
      scope = scope.where(feed_id: feed_id) if feed_id.present?
      scope = scope.where(status: status) if status.present?

      Page.of(scope, after: after, limit: limit)
    end

    field :audit_events, Types::AuditEventPageType, null: false, grants: "uris:catalog:read" do
      argument :status, String, required: false
      argument :actor, String, required: false
      argument :feed, ID, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def audit_events(status: nil, actor: nil, feed: nil, after: nil, limit: nil)
      scope = AuditEvent.includes(:feed, analysis: :feed)
      scope = scope.where(status: status) if status.present?
      scope = scope.where(actor: actor) if actor.present?
      scope = scope.where(feed_id: feed).or(scope.where(analysis: Analysis.where(feed_id: feed))) if feed.present?

      Page.of(scope, after: after, limit: limit)
    end
  end
end
