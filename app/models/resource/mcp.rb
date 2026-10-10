class Resource
  class Mcp < Resource
    include PublicFetch
    include Delegated

    SCOPE = "xixo:mcp:call".freeze
    JOINER = "__".freeze
    AUTHS = %w[none bearer basic header masks].freeze
    MASKS = "masks".freeze
    PROVIDER = /\A[a-z0-9][a-z0-9-]{0,62}\z/
    HELD_BY_MASKS = %w[delegation upstream].freeze
    HEADER_NAME = /\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/
    RESERVED_HEADERS = %w[
      host content-length content-type accept accept-encoding transfer-encoding connection upgrade te
      trailer keep-alive cookie user-agent last-event-id
    ].freeze
    PREFIX = /\A[a-z0-9][a-z0-9-]{0,30}\z/
    MAX_TOOLS = 40
    MAX_PARTS = 50
    PARTS = %w[text image audio resource resource_link].freeze
    HINTS = { "readOnlyHint" => :read_only_hint, "destructiveHint" => :destructive_hint,
              "idempotentHint" => :idempotent_hint, "openWorldHint" => :open_world_hint }.freeze

    Relayed = Data.define(:content, :structured, :error) do
      def to_h
        { content: content, structured_content: structured, error: error }.compact
      end
    end

    serves :tools

    def self.delegated?
      false
    end

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "An MCP server",
        blurb: "Somebody else's tools, offered beside the catalog's own. Checking it asks " \
               "what it can do; its tools then answer under this resource's key, so two " \
               "servers can both have a search without colliding.",
        names: "The prefix its tools answer under",
        fields: [
          field("url", "Address", required: true, placeholder: "https://mcp.example.com/mcp"),
          field("auth", "Authentication", kind: "choice", value: "none",
                options: [
                  { value: "none", label: "None" },
                  { value: "bearer", label: "Bearer token" },
                  { value: "basic", label: "Username and password" },
                  { value: "header", label: "A header of its own" },
                  { value: MASKS, label: "Your own account, through masks" }
                ]),
          field("provider", "Provider in masks", required: true, placeholder: "notion",
                help: "The key masks knows this server's authorization server by. Attaching sends you to " \
                      "masks to connect your account, and xixo never sees a password or a pasted token.",
                shown_when: { "auth" => MASKS }),
          field("token", "Bearer token", required: true, secret: true,
                help: "Sent as Authorization: Bearer.", shown_when: { "auth" => "bearer" }),
          field("username", "Username", required: true, held: :credentials,
                shown_when: { "auth" => "basic" }),
          field("password", "Password", required: true, secret: true, shown_when: { "auth" => "basic" }),
          field("header_name", "Header", required: true, placeholder: "X-API-Key",
                shown_when: { "auth" => "header" }),
          field("header_value", "Value", required: true, secret: true,
                help: "Sent as it is typed, on every request.", shown_when: { "auth" => "header" })
        ]
      }
    end

    def self.command_schema
      { tools: {}, call: { name: "string", arguments: "json?" } }
    end

    def self.permitted_origins
      PublicAddress.origins(ENV.fetch("XIXO_MCP_ORIGINS", ""))
    end

    def self.named?(target)
      permitted_origins.include?(PublicAddress.origin(target))
    end

    before_validation :forget_what_masks_held, if: -> { !delegated? || pointed_elsewhere? }
    after_destroy_commit { Sessions.forget(id) }

    validate :it_names_an_address
    validate :its_key_can_prefix_a_tool
    validate :it_does_not_point_at_us
    validate :it_authenticates_the_way_it_says

    def url
      details.to_h["url"].to_s
    end

    def offered
      Array(details.to_h["tools"])
    end

    def auth
      details.to_h["auth"].presence || "none"
    end

    def delegated?
      auth == MASKS
    end

    def needs_connect?
      delegated? && super
    end

    def provider_key
      details.to_h["provider"].to_s
    end

    def check!
      discover!
      true
    end

    def discover!
      found = connected { |client| client.tools.first(MAX_TOOLS) }
      listed = found.map do |tool|
        { "name" => tool.name.to_s, "description" => tool.description.to_s,
          "input_schema" => tool.input_schema.to_h, "annotations" => tool.annotations.to_h.presence }.compact
      end

      update!(details: details.to_h.merge("tools" => listed))
      listed
    end

    def invoke!(name, arguments = {})
      answered = connected do |client|
        client.call_tool(name: name, arguments: arguments.to_h.deep_stringify_keys)
      end

      answer(name, answered)
    end

    def proxied_tools
      offered.filter_map { |definition| proxy(definition) }
    end

    def command_tools
      { count: offered.size, tools: offered }
    end

    def command_call(name:, arguments: nil)
      invoke!(name, arguments || {}).to_h
    end

    private

      def private_fetch?(target)
        super || self.class.named?(target)
      end

      def connected(retried: false, expired: false, &block)
        Sessions.with(id, fingerprint, -> { MCP::Client.new(transport: transport) }, &block)
      rescue MCP::Client::SessionExpiredError
        raise Resource::Failed, "#{key}: #{url} ended its session twice running" if expired

        connected(retried: retried, expired: true, &block)
      rescue MCP::Client::RequestHandlerError => e
        if unauthorized?(e) && delegated?
          return connected(retried: true, &block) if !retried && token_expired!

          raise Resource::Unusable, "#{key}: #{url} refused the token masks released — connect it again"
        end

        raise Resource::Failed, "#{key}: #{url} answered #{e.message}"
      rescue MCP::Client::ServerError => e
        raise Resource::Failed, "#{key}: #{url} answered #{e.message}"
      rescue PublicFetch::Blocked, Resource::Failed
        raise
      rescue StandardError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching #{url} — #{e.message}"
      end

      def fingerprint
        Digest::SHA256.hexdigest([ id, url, headers.sort ].to_json)
      end

      def transport
        pinned = pinned!(url)
        overheard!(pinned)

        MCP::Client::HTTP.new(url: pinned.uri.to_s, headers: headers) do |faraday|
          faraday.adapter(:net_http) { |http| http.ipaddr = pinned.address }
        end
      end

      def headers
        { "User-Agent" => "xixo" }.merge(authorization.compact)
      end

      def authorization
        held = credentials.to_h

        case auth
        when "bearer" then { "Authorization" => "Bearer #{held['token']}" }
        when "basic" then { "Authorization" => "Basic #{Base64.strict_encode64("#{held['username']}:#{held['password']}")}" }
        when "header" then { details.to_h["header_name"].to_s => held["header_value"].to_s }
        when MASKS then { "Authorization" => "Bearer #{upstream_token}" }
        else {}
        end
      end

      def forget_what_masks_held
        return if (credentials.to_h.keys & HELD_BY_MASKS).empty?

        self.credentials = credentials.to_h.except(*HELD_BY_MASKS)
        self.connected_by = nil
      end

      def pointed_elsewhere?
        return false if new_record?

        was = details_was.to_h
        was["url"] != url || was["provider"].to_s != provider_key
      end

      def unauthorized?(error)
        error.error_type == :unauthorized
      end

      def overheard!(pinned)
        return if auth == "none" || pinned.uri.scheme == "https"
        return if PublicAddress.reserved?(IPAddr.new(pinned.address))

        raise PublicFetch::Blocked,
              "#{key}: #{pinned.uri.host} is plain http, and its credentials would cross the internet readable"
      end

      def answer(name, answered)
        result = answered.is_a?(Hash) ? answered["result"].to_h : {}
        parts = Array(result["content"]).select { |part| part.is_a?(Hash) && PARTS.include?(part["type"]) }

        if parts.empty? && result["structuredContent"].nil? && !result["isError"]
          parts = [ { "type" => "text", "text" => "#{name} answered with nothing" } ]
        end

        Relayed.new(
          content: parts.first(MAX_PARTS),
          structured: result["structuredContent"].is_a?(Hash) ? result["structuredContent"] : nil,
          error: result["isError"] == true
        )
      end

      def hinted(definition)
        given = definition["annotations"].to_h
        hints = HINTS.filter_map { |said, named| [ named, given[said] ] if [ true, false ].include?(given[said]) }.to_h

        given["title"].is_a?(String) ? hints.merge(title: given["title"]) : hints
      end

      def proxy(definition)
        remote = definition["name"].to_s
        return nil if remote.blank?

        held = id
        place = key
        local = "#{key}#{JOINER}#{remote}"
        told = definition["description"].to_s
        shape = definition["input_schema"].to_h.symbolize_keys
        hints = hinted(definition)

        Class.new(Tool::Base) do
          tool_name local
          scope SCOPE
          description told
          input_schema(properties: shape[:properties].to_h, required: Array(shape[:required]))
          annotations(**hints) if hints.any?

          define_singleton_method(:saying) { |_arguments| "called #{remote} on #{place}" }

          define_singleton_method(:call) do |server_context:, **arguments|
            relay(server_context, arguments) do
              Resource.visible_to(Current.grant).find(held).invoke!(remote, arguments)
            end
          end
        end
      end

      def it_names_an_address
        errors.add(:details, "must name a url") if url.blank?
      end

      def its_key_can_prefix_a_tool
        return if key.to_s.match?(PREFIX)

        errors.add(:key, "is letters, numbers and dashes, so it can prefix a tool name")
      end

      def it_authenticates_the_way_it_says
        return errors.add(:details, "authenticates with #{AUTHS.join(', ')}") unless AUTHS.include?(auth)

        wanted = { "bearer" => %w[token], "basic" => %w[username password], "header" => %w[header_value] }
                 .fetch(auth, [])
        held = credentials.to_h.compact_blank.except(*HELD_BY_MASKS)

        (wanted - held.keys).each { |name| errors.add(:credentials, "needs #{name} to authenticate with #{auth}") }
        (held.keys - wanted).each { |name| errors.add(:credentials, "carries #{name}, which #{auth} does not send") }

        its_header_is_one_it_may_send if auth == "header"
        its_provider_is_named if delegated?
      end

      def its_provider_is_named
        errors.add(:details, "names the provider in masks it connects through") unless provider_key.match?(PROVIDER)
      end

      def its_header_is_one_it_may_send
        name = details.to_h["header_name"].to_s

        unless name.match?(HEADER_NAME)
          return errors.add(:details, "names a header of letters, numbers and dashes")
        end

        if RESERVED_HEADERS.include?(name.downcase) || name.downcase.start_with?("mcp-", "proxy-")
          errors.add(:details, "names #{name}, which the connection sets for itself")
        end

        return unless credentials.to_h["header_value"].to_s.match?(/[\r\n\0]/)

        errors.add(:credentials, "carries a header value that runs onto another line")
      end

      def it_does_not_point_at_us
        suffix = ENV["XIXO_HOST_SUFFIX"].presence
        return if suffix.nil? || url.blank?

        host = URI.parse(url).host.to_s
        return unless host == suffix || host.end_with?(".#{suffix}")

        errors.add(:details, "points back at xixo, which would call itself")
      rescue URI::InvalidURIError
        errors.add(:details, "is not a url")
      end
  end
end
