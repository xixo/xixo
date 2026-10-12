module Tables
  ROWS = 5_000
  CELLS = 64
  OPS = %w[sum count average min max].freeze
  DAY = /\A\d{4}-\d{2}-\d{2}/
  FLIPPED = { "<" => ">", ">" => "<", "<=" => ">=", ">=" => "<=" }.freeze
  TESTS = %w[contains equals starts > < >= <=].freeze
  SHOWN = 2
  SPREAD = 4

  class Refused < StandardError; end

  class << self
    def of(feed)
      held = feed.analysis&.step_result("tables")
      Array(held).filter_map { |table| sound(table) }
    end

    def sound(table)
      return nil unless table.is_a?(Hash) && table["name"].is_a?(String)

      columns = table["columns"]
      rows = table["rows"]
      return nil unless columns.is_a?(Array) && columns.any? && rows.is_a?(Array)

      named = columns.first(CELLS).map(&:to_s)
      kept = rows.first(ROWS).select { |row| row.is_a?(Array) }.map { |row| row.first(named.size).map { |cell| cell.is_a?(Hash) || cell.is_a?(Array) ? cell.to_s : cell } }

      { "name" => table["name"], "columns" => named, "rows" => kept }
    end

    def described(table)
      shown = table["rows"].first(SHOWN).map { |row| table["columns"].zip(row).to_h.to_json }
      "#{table['name']}: #{table['columns'].join(', ')} (#{table['rows'].size} rows), such as #{shown.join(' and ')}"
    end

    def shape(table)
      [ described(table), "Across its rows, the values run #{spread(table, table['rows']).join('; ')}." ].join("\n")
    end

    def compute(tables, spec)
      spec = spec.to_h.transform_keys(&:to_s)
      table = tables.find { |held| held["name"].casecmp?(spec["table"].to_s) } || (tables.first if tables.one?)
      raise Refused, "no table called #{spec['table']}" if table.nil?

      op = spec["op"].to_s.downcase
      raise Refused, "op is one of #{OPS.join(', ')}" unless OPS.include?(op)

      rows = Array(spec["where"]).reduce(table["rows"]) { |held, test| filtered(table, held, test) }
      matched = { "rows" => rows.size, "spread" => spread(table, rows.presence || table["rows"]) }
      return { "op" => op, "value" => rows.size }.merge(matched) if op == "count"

      at = column(table, spec["column"])
      values = rows.filter_map { |row| number(row[at]) }
      raise Refused, "no numbers in #{spec['column']} among the #{rows.size} rows that matched" if values.empty?

      { "op" => op, "column" => table["columns"][at], "value" => reduced(op, values).round(2) }.merge(matched)
    end

    private

      def spread(table, rows)
        table["columns"].each_with_index.filter_map do |name, at|
          values = rows.map { |row| row[at] }.compact
          next if values.empty?

          numbers = values.filter_map { |value| number(value) }
          next "#{name} from #{numbers.min} to #{numbers.max}" if numbers.size == values.size

          texts = values.map(&:to_s)
          next "#{name} from #{texts.min} to #{texts.max}" if values.size >= SPREAD && texts.uniq.size * 2 > texts.size

          common = values.tally.max_by(SPREAD) { |_, count| count }.map { |value, count| "#{value} (#{count})" }
          "#{name}: #{common.join(', ')}"
        end
      end

      def filtered(table, rows, test)
        name, how, wanted = Array(test)
        how = how.to_s.downcase
        raise Refused, "a test is one of #{TESTS.join(', ')}" unless TESTS.include?(how)

        at = column(table, name)
        sized = outgoing?(table, at)
        rows.select { |row| passes?(row[at], how, wanted, sized: sized) }
      end

      def outgoing?(table, at)
        numbers = table["rows"].map { |row| number(row[at]) }
        numbers.compact.any? && numbers.all? { |held| held.nil? || held <= 0 }
      end

      def passes?(cell, how, wanted, sized:)
        text = cell.to_s.downcase
        sought = wanted.to_s.downcase

        case how
        when "contains" then text.include?(sought)
        when "equals" then text == sought || (number(cell) && number(cell) == number(wanted))
        when "starts" then text.start_with?(sought)
        else
          held = number(cell)
          bound = number(wanted)
          return dated?(cell, how, wanted) if held.nil? || bound.nil?

          if sized
            how = FLIPPED.fetch(how, how) if bound.negative?
            held, bound = held.abs, bound.abs
          end

          held.public_send(how, bound)
        end
      end

      def dated?(cell, how, wanted)
        held = day(cell)
        bound = day(wanted)
        !held.nil? && !bound.nil? && held.public_send(how, bound)
      end

      def day(value)
        text = value.to_s.strip
        return nil unless text.match?(DAY)

        Date.iso8601(text[DAY])
      rescue Date::Error
        nil
      end

      def column(table, name)
        at = table["columns"].index { |held| held.casecmp?(name.to_s.strip) }
        raise Refused, "no column called #{name}; the columns are #{table['columns'].join(', ')}" if at.nil?

        at
      end

      def number(value)
        return value.to_f if value.is_a?(Numeric)

        cleaned = value.to_s.delete(",$€£ ").strip
        cleaned.match?(/\A-?\d+(\.\d+)?\z/) ? cleaned.to_f : nil
      end

      def reduced(op, values)
        case op
        when "sum" then values.sum
        when "average" then values.sum / values.size
        when "min" then values.min
        when "max" then values.max
        end
      end
  end
end
