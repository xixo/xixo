module ReferencePages
  class Resources < Page
    ROOTS = "XIXO_FILESYSTEM_ROOTS".freeze
    EXAMPLE_ROOT = "/data/files".freeze

    def slug = "resources"
    def title = "Resource types"
    def description = "Every type of resource, what each serves and accepts, and what it needs to attach."

    def intro
      <<~TEXT
        A [resource](/concepts/resources/) is an instance of one of these types. What a type serves
        decides where xixo uses it; what it accepts, and up to what size, decides whether a file may be
        [placed](/concepts/adding/) in it. A type with fields can be attached from the app or declared in
        `config/resources.yml`; one without is made by xixo or a sign-in flow.
      TEXT
    end

    def body
      with_roots do
        [ table([ "Type", "Serves", "Syncs" ], types.map { |klass| summary(klass) }),
          *types.map { |klass| describe(klass) } ]
      end
    end

    private

      def types
        ::Resource::TYPES.map { |name| ::Resource.find_sti_class(name) }
      end

      def with_roots
        held = ENV[ROOTS]
        ENV[ROOTS] = EXAMPLE_ROOT
        yield
      ensure
        ENV[ROOTS] = held
      end

      def summary(klass)
        [ "[#{code(klass.sti_name)}](##{klass.sti_name})", listed(klass.serves), klass.method_defined?(:each_page) ? "yes" : "" ]
      end

      def listed(values)
        values.empty? ? "—" : values.map { |value| code(value) }.join(" ")
      end

      def describe(klass)
        attaching = klass.attaching

        [
          "## #{klass.sti_name}\n",
          *(("#{prose(attaching[:label])}. #{prose(attaching[:blurb])}\n") if attaching),
          facts(klass),
          *(fields(attaching) if attaching),
          commands(klass)
        ].join("\n")
      end

      def facts(klass)
        rows = [
          [ "Serves", listed(klass.serves) ],
          [ "Accepts", listed(klass.accepts) ],
          [ "Up to", klass.up_to ? ActiveSupport::NumberHelper.number_to_human_size(klass.up_to) : "—" ],
          [ "Syncs", klass.method_defined?(:each_page) ? "yes" : "no" ],
          [ "Connected through masks", klass.delegated? ? "yes" : "no" ],
          [ "Reached through a transport", klass.routable? ? "yes" : "no" ],
          [ "Attached from the app", klass.attaching ? "yes" : "no" ]
        ]

        table([ "", "" ], rows)
      end

      def fields(attaching)
        rows = attaching[:fields].map do |field|
          [ code(field[:name]), prose(field[:label]), kind_of(field), field[:required] ? "yes" : "",
            field[:held] == :credentials ? "encrypted" : "", asked_when(field), prose(field[:help]) ]
        end

        "### Fields\n\n#{table([ 'Field', 'Label', 'Kind', 'Required', 'Held', 'Asked when', 'Help' ], rows)}"
      end

      def kind_of(field)
        return field[:kind] if field[:options].nil?

        "#{field[:kind]} of #{field[:options].map { |option| code(option[:value]) }.join(' ')}"
      end

      def asked_when(field)
        return "" if field[:shown_when].nil?

        field[:shown_when].map { |name, values| "#{code(name)} is #{Array(values).map { |value| code(value) }.join(' or ')}" }
                          .join(", ")
      end

      def commands(klass)
        rows = klass.command_schema.map do |name, arguments|
          taken = arguments.map { |argument, type| code("#{argument}: #{type}") }.join(" ")

          [ code(name), taken.presence || "—" ]
        end

        return "" if rows.empty?

        "### Commands\n\n#{table([ 'Command', 'Arguments' ], rows)}"
      end
  end
end
