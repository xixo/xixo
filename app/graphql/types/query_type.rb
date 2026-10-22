# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    field :tenant, Types::TenantType, null: true, grants: "xixo:catalog:read"

    def tenant
      context[:tenant]
    end

    field :administrator, Boolean, null: false, grants: "xixo:resources:read",
          description: "Whether this token carries xixo:settings:admin, so it attaches, changes, and " \
                       "removes the resources everyone shares and chooses the defaults."

    def administrator
      context[:grant].administers?
    end

    field :setup, Types::SetupType, null: false, grants: "xixo:resources:read",
          description: "What a new install still needs: storage, a model server, and an MCP client."

    def setup
      {}
    end

    field :server_updates, Types::ServerUpdatesType, grants: "xixo:settings:read",
          description: "How xixo-updater keeps this server up to date. Empty for anyone but an administrator of the " \
                       "tenant that runs the server's updates, named by XIXO_UPDATES_TENANT or XIXO_TENANT."

    def server_updates
      return nil unless context[:grant].administers? && ServerUpdates.controlled_by?(context[:tenant])

      { status: ServerUpdates.status, events: ServerUpdates.events }
    end

    field :settings, [ Types::SettingType ], null: false, grants: "xixo:settings:read"

    def settings
      grant = context[:grant]
      subject = grant.subject

      stored = Setting.where(subject: [ nil, subject ]).to_h { |held| [ [ held.key, held.subject ], held.value ] }

      Setting::LEVELS.flat_map { |level| Setting.at(level) }
                     .select { |definition| grant.permits?(definition.reads) }
                     .map do |definition|
        owner = definition.personal? ? subject : nil
        definition.to_h.merge(value: stored.fetch([ definition.key, owner ], definition.default))
      end
    end

    field :feed, Types::FeedType, null: true, grants: "xixo:catalog:read" do
      argument :id, ID, required: false
      argument :key, String, required: false, description: "An address, as /buy."
    end

    def feed(id: nil, key: nil)
      return readable.for_rows.find_by(id: id) if id.present?

      readable.for_rows.address(key) if key.present?
    end

    field :feeds, Types::FeedPageType, null: false, grants: "xixo:catalog:read" do
      argument :type, String, required: false
      argument :types, [ String ], required: false, description: "Any of these types, instead of one."
      argument :mime, String, required: false
      argument :resource_id, ID, required: false
      argument :tag, String, required: false,
               description: "A tag key, for everything connected to it."
      argument :connected_to, ID, required: false
      argument :top_level, Boolean, required: false,
               description: "Only what was not extracted from something else."
      argument :slice, Types::SliceInput, required: false,
               description: "Where it lives, its analysis state, its kind, and when it was added."
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def feeds(type: nil, types: nil, mime: nil, resource_id: nil, tag: nil, connected_to: nil,
              top_level: false, slice: nil, after: nil, limit: nil)
      scope = sliced(listed(types.presence || type, mime: mime, resource_id: resource_id, tag: tag,
                            connected_to: connected_to, top_level: top_level), slice)

      Page.of(scope.for_rows, after: after, limit: limit)
    end

    field :search, Types::FeedPageType, null: false, grants: "xixo:catalog:read" do
      argument :query, String, required: false
      argument :type, String, required: false
      argument :types, [ String ], required: false, description: "Any of these types, instead of one."
      argument :slice, Types::SliceInput, required: false,
               description: "Where it lives, its analysis state, its kind, and when it was added. A search " \
                            "narrowed this way ranks its best #{SearchIndex::CANDIDATES} matches."
      argument :after, ID, required: false,
               description: "How far into the matches to start. A search is walked by offset."
      argument :limit, Integer, required: false
    end

    def search(query: nil, type: nil, types: nil, slice: nil, after: nil, limit: nil)
      Feed.found(query, type: types.presence || type, from: after.to_i,
                        limit: (limit || Page::DEFAULT).to_i.clamp(1, Page::MAX), slice: slice_of(slice))
    end

    field :slice_counts, Types::SliceCountsType, null: false, grants: "xixo:catalog:read",
          description: "How many feeds each choice of a slice would list, for the same listing or search the " \
                       "slice narrows. A search counts among its best #{SearchIndex::CANDIDATES} matches." do
      argument :query, String, required: false
      argument :types, [ String ], required: false
      argument :connected_to, ID, required: false
      argument :top_level, Boolean, required: false
      argument :slice, Types::SliceInput, required: false
    end

    def slice_counts(query: nil, types: nil, connected_to: nil, top_level: false, slice: nil)
      base = if query.present?
        found = SearchIndex.page(query, type: types.presence, limit: SearchIndex::CANDIDATES, from: 0)
        readable.where(id: found[:ids])
      else
        listed(types.presence, connected_to: connected_to, top_level: top_level)
      end

      slice_of(slice).counts(base)
    end

    field :types, [ Types::TypeCountType ], null: false, grants: "xixo:catalog:read"

    def types
      readable.where(parent_id: nil).group(:type).order(count_all: :desc).count.map do |type, count|
        { type: type, count: count }
      end
    end

    field :resources, [ Types::ResourceType ], null: false, grants: "xixo:resources:read" do
      argument :archived, Boolean, required: false,
               description: "Left off, the ones still in use. True, the ones put away."
    end

    def resources(archived: false)
      scope = archived ? Resource.attended.reachable_by(context[:grant]).where.not(archived_at: nil) : Resource.visible_to(context[:grant])

      scope.includes(:via).order(:type, :key)
    end

    field :waiting_for_machines, [ Types::WaitingFilesType ], null: false, grants: "xixo:resources:read",
          description: "Files from no machine in particular, or from one that lends them, whose reading waits " \
                       "for a connected machine that reads for others and has their program, by kind."

    def waiting_for_machines = Types::WaitingFilesType.on(context, nil)

    field :discovered, [ Types::DiscoveredNodeType ], null: false, grants: "xixo:resources:read",
          extras: [ :lookahead ],
          description: "What a transport reaches, offered as resources to attach: the folders a machine running " \
                       "xixo link shares." do
      argument :via, String, required: true, description: "The key of the transport."
    end

    def discovered(via:, lookahead:)
      Resource.transport!(via, context[:grant]).discovered(services: lookahead.selects?(:services))
    rescue Resource::Refused, Resource::Failed => e
      raise GraphQL::ExecutionError, e.message
    end

    field :link_up, Types::LinkUpType, grants: "xixo:resources:read",
          description: "What the command that links up a machine needs. Empty for anyone but an administrator, " \
                       "who alone approves machines."

    def link_up
      return nil unless context[:grant].administers?

      { xixo: context[:origin] || context[:tenant].origin,
        systems: Resource::Machine::Downloads.builds.map(&:os).uniq & Resource::Machine::Script::SYSTEMS.keys }
    rescue Tenant::Unconfigured
      nil
    end

    field :link_requests, [ Types::LinkRequestType ], null: false, grants: "xixo:resources:read",
          description: "The machines asking to link up, and those approved in the last ten minutes. Empty for " \
                       "anyone but an administrator."

    def link_requests
      return [] unless context[:grant].administers?

      LinkRequest.shown.includes(:resource)
    end

    field :link_request, Types::LinkRequestType, grants: "xixo:resources:read",
          description: "The machine asking to link up with the code it shows. Empty for anyone but an administrator." do
      argument :code, String, required: true
    end

    def link_request(code:)
      return nil unless context[:grant].administers?

      LinkRequest.by_code(code)
    end

    field :resource_types, [ Types::AttachingType ], null: false, grants: "xixo:resources:read",
          description: "Every type that can be attached, and what each of them needs."

    def resource_types
      Resource.attachable.map do |klass|
        klass.attaching.merge(
          type: klass.sti_name,
          capabilities: klass.capabilities.map(&:to_s),
          syncs: klass.method_defined?(:each_page),
          delegated: klass.delegated?,
          routable: klass.routable?,
          addressed_by: klass.addressed_by
        )
      end
    end

    field :run, Types::RunType, null: true, grants: "xixo:catalog:read" do
      argument :id, ID, required: true
    end

    def run(id:)
      Run.visible_to(context[:grant]).find_by(id: id)
    end

    field :runs, Types::RunPageType, null: false, grants: "xixo:catalog:read" do
      argument :kind, String, required: false
      argument :resource_id, ID, required: false, description: "Only the runs of this resource."
      argument :status, String, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def runs(kind: nil, status: nil, resource_id: nil, after: nil, limit: nil)
      scope = Run.visible_to(context[:grant])
      scope = scope.where(kind: kind) if kind.present?
      scope = scope.where(resource_id: resource_id) if resource_id.present?
      scope = scope.where(status: status) if status.present?

      Page.of(scope, after: after, limit: limit)
    end

    field :analysis, Types::AnalysisType, null: true, grants: "xixo:catalog:read" do
      argument :id, ID, required: true
    end

    def analysis(id:)
      Analysis.readable_by(context[:grant]).find_by(id: id)
    end

    field :analyses, Types::AnalysisPageType, null: false, grants: "xixo:catalog:read" do
      argument :feed_id, ID, required: false
      argument :status, String, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def analyses(feed_id: nil, status: nil, after: nil, limit: nil)
      scope = Analysis.readable_by(context[:grant])
      scope = scope.where(feed_id: feed_id) if feed_id.present?
      scope = scope.where(status: status) if status.present?

      Page.of(scope, after: after, limit: limit)
    end

    field :audit_events, Types::AuditEventPageType, null: false, grants: "xixo:catalog:read" do
      argument :status, String, required: false
      argument :actor, String, required: false
      argument :feed, ID, required: false
      argument :after, ID, required: false
      argument :limit, Integer, required: false
    end

    def audit_events(status: nil, actor: nil, feed: nil, after: nil, limit: nil)
      scope = AuditEvent.readable_by(context[:grant]).includes(:feed, analysis: :feed)
      scope = scope.where(status: status) if status.present?
      scope = scope.where(actor: actor) if actor.present?
      scope = scope.where(feed_id: feed).or(scope.where(analysis: Analysis.where(feed_id: feed))) if feed.present?

      Page.of(scope, after: after, limit: limit)
    end

    private

      def readable
        Feed.readable_by(context[:grant])
      end

      def listed(type, mime: nil, resource_id: nil, tag: nil, connected_to: nil, top_level: false)
        scope = readable.matching({ type: type, mime: mime, resource_id: resource_id, tag: tag }.compact)
        scope = scope.where(parent_id: nil) if top_level
        scope = scope.where(id: Feed.connected_to(readable.find(connected_to)).select(:id)) if connected_to.present?
        scope
      end

      def slice_of(given)
        Feed::Slice.from(given, grant: context[:grant])
      rescue ArgumentError => e
        raise GraphQL::ExecutionError, e.message
      end

      def sliced(scope, given)
        slice_of(given).apply(scope)
      end
  end
end
