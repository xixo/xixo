module Tool
  class Resources < Base
    tool_name "resource"
    scope "uris:resources:read"

    READ = %w[list describe runs get parameters search forecast find reverse nearby].freeze
    PLACES = %w[find reverse nearby].freeze
    WRITE = %w[check sync keep export cancel put snapshot].freeze
    RUNS = %w[sync export].freeze

    KEEPING = %w[snapshot].freeze

    WRITES = "uris:resources:command".freeze
    WEB = "uris:web:read".freeze
    KEEP = "uris:web:keep".freeze

    description <<~TEXT
      Ask a place to do something. A resource is an instance — "my B2 bucket" — of a type
      such as s3, and each type accepts its own commands; describe tells you which. Called
      with no key it lists the places there are. Some places reach the web: one that can
      search takes do=search with input {"query": "..."}, and one that can fetch reads a page
      with do=get and input {"url": "https://..."}, and one that serves weather takes
      do=forecast with input {"place": "Toronto"}, and one that knows places takes do=find with input
      {"query": "..."}, do=reverse with a latitude and longitude, or do=nearby with a kind such as
      cafe and a place. Credentials never travel through here:
      connecting a resource is a browser flow.
    TEXT

    def self.for(grant)
      allowed = (READ + (grant.permits?(WRITES) ? WRITE : []) + (grant.permits?(KEEP) ? KEEPING : [])).uniq

      Class.new(self) do
        tool_name "resource"
        scope "uris:resources:read"
        description Resources.description

        input_schema(
          properties: {
            key: { type: "string", description: "Which place. Left off, they are all listed." },
            do: { type: "string", enum: allowed, description: "What to ask of it." },
            input: { type: "object", description: "Arguments the command takes." }
          }
        )
      end
    end

    input_schema(
      properties: {
        key: { type: "string" },
        do: { type: "string", enum: READ + WRITE },
        input: { type: "object" }
      }
    )

    def self.call(server_context:, key: nil, input: nil, **held)
      verb = (held[:do] || held["do"] || (key.present? ? "describe" : "list")).to_s
      given = (input || {}).to_h

      respond(server_context, { key: key, do: verb, input: given }) do
        raise ArgumentError, "no such action '#{verb}'" unless (READ + WRITE).include?(verb)

        permitted!(verb)

        verb == "list" && key.blank? ? listed : acted(verb, key, given)
      end
    end

    SAID = {
      "list" => "listed the places", "describe" => "looked at", "runs" => "looked at the runs of",
      "check" => "checked", "sync" => "synced", "cancel" => "cancelled a run on", "export" => "exported to",
      "keep" => "kept a page through", "snapshot" => "snapshotted a page through", "put" => "stored a file in",
      "parameters" => "read the parameters of"
    }.freeze

    def self.saying(arguments)
      verb = arguments[:do].to_s
      given = arguments[:input].to_h.stringify_keys
      place = arguments[:key].presence
      return SAID["list"] if place.nil?

      case verb
      when "search" then "searched the web for #{given['query']} through #{place}"
      when "get" then given["url"].present? ? "read #{given['url']} through #{place}" : "asked #{place} for something"
      when "keep", "snapshot" then "#{SAID[verb].delete_suffix(' through')} #{given['url']} through #{place}".squish
      else "#{SAID.fetch(verb, "asked #{verb} of")} #{place}"
      end
    end

    def self.acted(verb, key, given)
      resource = ::Resource.visible_to(Current.grant).find_by(key: key) ||
                 raise(ArgumentError, "no resource called #{key}")

      Current.grant.permit!(WEB) if verb == "search" && resource.capabilities.include?(:search)
      Current.grant.permit!(WEB) if verb == "get" && resource.capabilities.include?(:fetch)
      Current.grant.permit!(WEB) if verb == "forecast" && resource.capabilities.include?(:weather)
      Current.grant.permit!(WEB) if PLACES.include?(verb) && resource.capabilities.include?(:places)
      kept!(resource) if KEEPING.include?(verb)
      within_budget! if RUNS.include?(verb)

      case verb
      when "describe" then resource.describe.merge(healthy: resource.healthy?)
      when "check" then { key: resource.key, healthy: resource.check, error: resource.check_error }
      when "sync" then started(resource)
      when "runs" then { runs: ::Run.where(resource: resource).newest_first.limit(20).map { |run| run_told(run) } }
      when "cancel" then cancelled(given)
      when "export" then exported(resource, given)
      when "keep", "snapshot" then kept(resource, verb, given)
      else resource.command(verb, given)
      end
    end

    def self.permitted!(verb)
      return unless WRITE.include?(verb)
      return Current.grant.permit!(WRITES) unless KEEPING.include?(verb) && Current.grant.permits?(KEEP)

      true
    end

    def self.kept!(resource)
      return if Current.grant.permits?(WRITES)
      return if resource.capabilities.include?(:browser)

      raise ArgumentError, "#{resource.key} does not keep pages from the web; #{KEEP} only snapshots through one that does"
    end

    def self.kept(resource, verb, given)
      lasts = given.delete("lasts") || given.delete(:lasts)
      answered = resource.command(verb, given)
      feed = answered.is_a?(Hash) && answered["id"] && ::Feed.find_by(id: answered["id"])
      return answered if feed.nil?

      if answered["new"]
        made!(feed)
        lasting(feed, lasts)
      elsif lasts.present?
        confined!(feed)
        feed.lasts!(lasts)
      end

      answered.merge("expires_at" => feed.expires_at)
    end

    def self.listed
      resources = ::Resource.visible_to(Current.grant).order(:type, :key).map do |resource|
        {
          id: resource.id.to_s, type: resource.class.sti_name, key: resource.key,
          name: resource.name, capabilities: resource.capabilities,
          accepts: resource.accepts, up_to: resource.up_to,
          commands: resource.class.command_schema.keys,
          default_storage: resource.default_storage?,
          default_inference: resource.default_inference?,
          syncable: resource.syncable?, syncing: resource.syncing?,
          synced_at: resource.synced_at, checked_at: resource.checked_at,
          check_error: resource.check_error
        }
      end

      { count: resources.size, resources: resources }
    end

    def self.started(resource)
      raise ArgumentError, "#{resource.key} is not syncable" unless resource.syncable?

      run = resource.sync!

      run ? run_told(run) : { started: false, reason: "#{resource.key} is already syncing" }
    end

    def self.exported(destination, given)
      destination.storage! || raise(ArgumentError, "#{destination.key} is not storage")

      selector = selector_from(**given.symbolize_keys.slice(*SELECTOR_KEYS))
      run = ::Run.start!(kind: "export", resource: destination, selector: selector)
      ExportItemsJob.perform_later(destination.tenant_id, destination.id, selector, run.id)

      run_told(run)
    end

    def self.cancelled(given)
      run = ::Run.visible_to(Current.grant).find_by(id: given[:id] || given["id"]) ||
            raise(ArgumentError, "no run with that id")

      run_told(run.tap(&:cancel!).reload)
    end

    SELECTOR_KEYS = %i[query type mime tag resource_id folder since before].freeze

    def self.run_told(run)
      {
        id: run.id.to_s, kind: run.kind, status: run.status, processed: run.processed,
        error: run.error, started_at: run.started_at, finished_at: run.finished_at
      }
    end
  end
end
