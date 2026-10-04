module ReferencePages
  class Mcp < Page
    def slug = "mcp"
    def title = "MCP tools"
    def description = "The tools /mcp offers, the scope each needs, and what each takes."

    def intro
      <<~TEXT
        `/mcp` speaks the Model Context Protocol over streamable HTTP, behind OAuth. A tool the token's
        scopes do not reach is absent from `tools/list`, not refused when it is called, and a
        `resource` command that needs `#{::Tool::Resources::WRITES}` is left out of that tool's schema
        in the same way. A token carrying `#{::Resource::Mcp::SCOPE}` also sees the tools of every MCP
        server attached as a resource, under that server's own names.
      TEXT
    end

    def body
      [ table([ "Tool", "Needs" ], tools.map { |tool| [ "[#{code(tool.tool_name)}](##{tool.tool_name})", code(tool.scope) ] }),
        *tools.map { |tool| describe(tool) },
        commands ]
    end

    private

      def tools = ::Tool.all

      def describe(tool)
        schema = tool.input_schema.to_h
        required = Array(schema[:required]).map(&:to_s)
        rows = schema.fetch(:properties, {}).map do |name, spec|
          [ code(name), kind(spec), required.include?(name.to_s) ? "yes" : "", prose(spec[:description]) ]
        end

        <<~TEXT
          ## #{tool.tool_name}

          Needs #{code(tool.scope)}.

          #{prose(tool.description)}

          #{table([ 'Argument', 'Type', 'Required', 'Description' ], rows)}
        TEXT
      end

      def kind(spec)
        held = spec[:type].to_s
        held = "#{held}, one of #{spec[:enum].map { |value| code(value) }.join(' ')}" if spec[:enum]
        held = "#{held}, #{spec[:minimum]}–#{spec[:maximum]}" if spec[:minimum] && spec[:maximum]
        held
      end

      def commands
        rows = (::Tool::Resources::READ + ::Tool::Resources::WRITE).map do |verb|
          needs = [ code(::Tool::Resources.scope) ]
          needs << code(::Tool::Resources::WRITES) if ::Tool::Resources::WRITE.include?(verb)
          needs << "#{code(::Tool::Resources::WEB)} on a search resource" if verb == "search"
          counted = ::Tool::Resources::RUNS.include?(verb) ? "yes" : ""

          [ code(verb), needs.join(" and "), counted ]
        end

        <<~TEXT
          ## Resource commands

          What `resource` accepts as `do`. `list`, `types`, `attach`, `change`, `default`, `describe`,
          `check`, `runs`, `sync`, `export` and `cancel` are answered by xixo itself; the rest are
          passed to the resource, and a type accepts only the ones its
          [reference entry](/reference/resources/) lists. A command that starts a run counts against
          the token's hourly run budget. `attach` and `change` refuse any field that holds a
          credential, and a type that always needs one is attached in the app. `change` keeps every
          setting it is not given.

          #{table([ 'Command', 'Needs', 'Starts a run' ], rows)}
        TEXT
      end
  end
end
