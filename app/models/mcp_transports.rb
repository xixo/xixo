module McpTransports
  INSTRUCTIONS = <<~TEXT.freeze
    xixo is one searchable index across everything its owner keeps, wherever it lives.

    A feed is a reference, not the bytes: the catalog holds where something lives and what
    analysis understood about it, while the original stays in the resource it came from.
    Files, notes, addresses, tags and content types are all feeds, and connecting two of them
    is how something is filed or related.

    Start with search. Read one feed with feed, file it with connect, and use resource to see
    the places things come from — describe a resource before commanding it, since each type
    has its own vocabulary.

    Credentials never travel through a tool call. Connecting a resource happens in the
    browser, and nothing here will accept a secret as an argument.
  TEXT

  SESSION_HEADER = "Mcp-Session-Id".freeze
  SESSION_TTL = 30.minutes
  LOCK = Mutex.new

  class << self
    def for(tenant:, grant:)
      key = [ tenant.id, grant.scopes.sort, proxied_at(grant) ]

      LOCK.synchronize { held[key] ||= build(tenant, grant) }
    end

    def claim(session_id, subject)
      return if session_id.blank?

      Rails.cache.fetch(cache_key(session_id), expires_in: SESSION_TTL) { subject.to_s }
    end

    def holds?(session_id, subject)
      held_subject = Rails.cache.read(cache_key(session_id))

      held_subject.nil? || held_subject == subject.to_s
    end

    def forget(session_id)
      Rails.cache.delete(cache_key(session_id))
    end

    def reset!
      LOCK.synchronize do
        held.each_value { |transport| transport.close rescue nil }
        @held = {}
      end
    end

    private

      def cache_key(session_id)
        "mcp:session:#{session_id}"
      end

      def proxied_at(grant)
        return nil unless grant.permits?(Resource::Mcp::SCOPE)

        found = Resource.active.where(type: Resource::Mcp.sti_name).reachable_by(grant)
        mine = found.where.not(owner_subject: nil).exists?

        [ found.count, found.maximum(:updated_at)&.to_f, (grant.subject if mine) ]
      end

      def held
        @held ||= {}
      end

      def build(tenant, grant)
        MCP::Server::Transports::StreamableHTTPTransport.new(
          server(tenant, grant),
          enable_json_response: true,
          dns_rebinding_protection: false,
          session_request_validator: ->(_request, session_id) {
            holds?(session_id, Current.grant&.subject)
          }
        )
      end

      def server(tenant, grant)
        MCP::Server.new(
          name: "xixo",
          title: "xixo",
          instructions: INSTRUCTIONS,
          tools: grant.tools,
          server_context: { tenant_id: tenant.id, scopes: grant.scopes }
        )
      end
  end
end
