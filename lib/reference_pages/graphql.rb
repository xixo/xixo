module ReferencePages
  class Graphql < Page
    SECTIONS = [
      [ "Queries", :query_root ],
      [ "Mutations", :mutation_root ],
      [ "Subscriptions", :subscription_root ],
      [ "Objects", :objects ],
      [ "Inputs", :inputs ],
      [ "Enums", :enums ],
      [ "Scalars", :scalars ]
    ].freeze

    def slug = "graphql"
    def title = "GraphQL"
    def description = "The schema served at /graphql, and the scope every field needs."

    def intro
      <<~TEXT
        Everything the browser app reads and changes. `/graphql` takes the session cookie the app
        signs in with, or a bearer token issued for this tenant. A field that names a scope refuses a
        caller whose token does not carry it; an object that names one resolves to nothing for them.
        Subscriptions are delivered over Action Cable at `/cable`.
      TEXT
    end

    def body
      SECTIONS.filter_map { |title, source| section(title, send(source)) }
    end

    private

      def schema = XixoSchema

      def section(title, types)
        return nil if types.empty?

        [ "## #{title}\n", *types.map { |type| describe(type) } ].join("\n")
      end

      def describe(type)
        body = if type.kind.enum?
          table([ "Value", "Description" ], type.values.values.map { |value| [ code(value.graphql_name), prose(value.description) ] })
        elsif type.kind.scalar?
          "A scalar, serialized as a string.\n"
        elsif type.kind.input_object?
          inputs_of(type)
        else
          fields(type)
        end

        "### #{type.graphql_name}\n\n#{documentation(type)}#{body}"
      end

      def documentation(type)
        notes = [ prose(type.description).presence ]
        guarded = type.respond_to?(:grants) ? type.grants : []
        notes << "Resolves only for a token carrying #{guarded.map { |scope| code(scope) }.join(' or ')}." if guarded.any?

        notes.compact.empty? ? "" : "#{notes.compact.join(' ')}\n\n"
      end

      def fields(type)
        values = type.fields.values.sort_by(&:graphql_name)
        described = values.any? { |field| field.description.present? }
        guarded = values.any? { |field| field.respond_to?(:grants) && field.grants.any? }

        headings = [ "Field", "Type", *("Needs" if guarded), *("Description" if described) ]
        rows = values.map do |field|
          [
            signature(field), link(field.type),
            *(needs(field) if guarded),
            *(prose(field.description) if described)
          ]
        end

        table(headings, rows)
      end

      def inputs_of(type)
        values = type.arguments.values.sort_by(&:graphql_name)
        described = values.any? { |argument| argument.description.present? }

        headings = [ "Argument", "Type", *("Description" if described) ]
        rows = values.map do |argument|
          [ code(argument.graphql_name), link(argument.type), *(prose(argument.description) if described) ]
        end

        table(headings, rows)
      end

      def needs(field)
        scopes = field.respond_to?(:grants) ? field.grants : []

        scopes.map { |scope| code(scope) }.join(" or ")
      end

      def signature(field)
        named = code(field.graphql_name)
        return named if field.arguments.empty?

        taken = field.arguments.values.map do |argument|
          "<br />#{code("#{argument.graphql_name}: #{argument.type.to_type_signature}")}"
        end

        "#{named}#{taken.join}"
      end

      def link(type)
        named = type.unwrap
        shown = type.to_type_signature

        return code(shown) if named.introspection? || named.kind.scalar?

        "[#{code(shown)}](##{named.graphql_name.downcase})"
      end

      def escaped(cell)
        cell.to_s.gsub("|", "\\|").gsub("\n", " ").gsub("{", "&#123;")
      end

      def declared
        @declared ||= schema.types.values.reject(&:introspection?).sort_by(&:graphql_name)
      end

      def roots
        [ schema.query, schema.mutation, schema.subscription ].compact
      end

      def query_root = [ schema.query ].compact
      def mutation_root = [ schema.mutation ].compact
      def subscription_root = [ schema.subscription ].compact

      def objects
        declared.select { |type| type.kind.object? } - roots
      end

      def inputs
        declared.select { |type| type.kind.input_object? }
      end

      def enums
        declared.select { |type| type.kind.enum? }
      end

      def scalars
        declared.select { |type| type.kind.scalar? && !type.default_scalar? }
      end
  end
end
