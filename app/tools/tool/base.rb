module Tool
  class OverBudget < StandardError; end

  class Base < MCP::Tool
    EXPECTED = [
      Grant::Denied,
      OverBudget,
      ArgumentError,
      ActiveRecord::RecordNotFound,
      ActiveRecord::RecordInvalid,
      Resource::Failed
    ].freeze

    class << self
      def scope(value = nil)
        @scope = value if value
        @scope
      end

      def respond(_server_context, arguments = {})
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        grant = Current.grant or raise Grant::Denied, "this call carries no grant"
        grant.permit!(scope)

        result = yield

        audit(grant, arguments, "ok", started)
        text(result.to_json)
      rescue *EXPECTED => e
        audit(Current.grant, arguments, refused?(e) ? "denied" : "error", started, e.message)

        text(e.message, error: true)
      end

      def relay(_server_context, arguments = {})
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        grant = Current.grant or raise Grant::Denied, "this call carries no grant"
        grant.permit!(scope)

        relayed = yield

        audit(grant, arguments, relayed.error ? "error" : "ok", started)
        MCP::Tool::Response.new(relayed.content, error: relayed.error, structured_content: relayed.structured)
      rescue *EXPECTED => e
        audit(Current.grant, arguments, refused?(e) ? "denied" : "error", started, e.message)

        text(e.message, error: true)
      end

      def refused?(error)
        error.is_a?(Grant::Denied) || error.is_a?(OverBudget)
      end

      def within_budget!(grant = Current.grant)
        limit = Rails.configuration.uris.run_budget
        return if limit.zero?

        key = [ "mcp:runs", Current.tenant.id, grant.subject, Time.current.to_i / 3600 ].join(":")
        spent = Rails.cache.increment(key, 1, expires_in: 1.hour)

        return if spent.nil? || spent <= limit

        raise OverBudget,
              "this token has started #{spent - 1} runs in the last hour, and #{limit} is the ceiling"
      end

      def audit(grant, arguments, status, started, detail = nil)
        AuditEvent.record(
          channel: "mcp", action: tool_name, status: status, scope: scope,
          grant: grant, context: Current.audit,
          told: safely { saying(arguments) }, feed: safely { about(arguments) },
          arguments: arguments, detail: detail,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        )
      end

      def saying(_arguments)
        nil
      end

      def about(_arguments)
        nil
      end

      def safely
        yield
      rescue StandardError
        nil
      end

      def named(id)
        feed = id.presence && Feed.find_by(id: id)
        feed ? (feed.title.presence || feed.key) : id.presence && "feed #{id}"
      end

      def text(body, error: false)
        MCP::Tool::Response.new([ { type: "text", text: body } ], error: error)
      end

      def lasting(feed, lasts)
        default = Current.confined_to ? Feed::KEPT_FOR : nil
        feed.lasts!(lasts, default: default)
      end

      def made!(feed)
        Current.confined_to&.add(feed.id)
        feed
      end

      def confined!(*feeds, also: nil)
        held = Current.confined_to
        return if held.nil?
        return if feeds.any? { |feed| held.include?(feed.id) || feed.id == also }

        raise ArgumentError, "this run can only change what it made itself, and #{feeds.map(&:id).join(' and ')} it did not make"
      end

      def feed!(id)
        Feed.find_by(id: id) || raise(ArgumentError, "no feed with id #{id}")
      end

      def resource!(id)
        Resource.visible_to(Current.grant).find_by(id: id) || raise(ArgumentError, "no resource with id #{id}")
      end

      def summarize(feed)
        {
          id: feed.id.to_s,
          type: feed.type,
          key: feed.key,
          title: feed.title,
          mime: feed.mime,
          analyzed_at: feed.analyzed_at,
          expires_at: feed.expires_at,
          references: feed.references.map { |reference| describe_reference(reference) }
        }
      end

      def describe_reference(reference)
        {
          id: reference.id.to_s,
          resource_id: reference.resource_id.to_s,
          resource: reference.resource.key,
          role: reference.role,
          mime: reference.mime,
          locator_key: reference.locator_key,
          analyzed_at: reference.analyzed_at,
          changed_at: reference.changed_at,
          gone_at: reference.gone_at
        }
      end

      def selector_from(query: nil, type: nil, mime: nil, tag: nil, resource_id: nil,
                        folder: nil, since: nil, before: nil)
        {
          "query" => query, "type" => type, "mime" => mime, "tag" => tag,
          "resource_id" => resource_id, "folder" => folder,
          "since" => since, "before" => before
        }.compact
      end
    end
  end
end
