module ReferencePages
  class Scopes < Page
    def slug = "scopes"
    def title = "Scopes"
    def description = "Every scope a token can carry for xixo, and what each one opens."

    def intro
      <<~TEXT
        xixo publishes its scopes beneath the `#{::Grant::NAMESPACE}` namespace of the masks tenant it
        signs in with. A token carries the ones its holder was granted; anything outside the namespace
        is ignored. `#{::Grant::ADMINISTRATIVE.join('`, `')}` is never asked for at sign-in.
      TEXT
    end

    def body
      [ table([ "Scope", "Means", "Asked at sign-in", "MCP tools", "GraphQL" ], ::Grant::SCOPES.map { |scope| row(scope) }) ]
    end

    private

      def row(scope)
        [
          code(scope),
          ::Grant::DESCRIBED.fetch(scope),
          ::Grant::SIGN_IN.include?(scope) ? "yes" : "no",
          tools_for(scope),
          fields_for(scope)
        ]
      end

      def tools_for(scope)
        named = ::Tool.all.select { |tool| tool.scope == scope }.map { |tool| code(tool.tool_name) }
        named << "proxied tools" if scope == ::Resource::Mcp::SCOPE
        named << "`resource` writes" if scope == ::Tool::Resources::WRITES

        named.join(" ").presence || "—"
      end

      def fields_for(scope)
        count = [ XixoSchema.query, XixoSchema.mutation, XixoSchema.subscription ].compact.sum do |root|
          root.fields.values.count { |field| field.respond_to?(:grants) && field.grants.include?(scope) }
        end

        count.zero? ? "—" : "#{count} root #{count == 1 ? 'field' : 'fields'}"
      end
  end
end
