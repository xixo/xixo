module Tables
  ROWS = 5_000
  HEADER_WITHIN = 10
  TOTALLED = /\A\s*(sub)?totals?\b/i
  OPS = %w[sum count average min max].freeze
  TESTS = %w[contains equals starts > < >= <=].freeze
  SHOWN = 2
  SPREAD = 4

  class Refused < StandardError; end

  class << self
    def framed(name, rows)
      rows = rows.map { |row| Array(row).map { |cell| cell.is_a?(String) ? cell.strip.presence : cell } }
      at = header_at(rows)
      return nil if at.nil?

      columns = rows[at].each_with_index.map { |cell, index| cell.to_s.presence || "Column #{index + 1}" }
      body = rows.drop(at + 1).reject { |row| row.compact.empty? }.first(ROWS)

      { "name" => name.to_s, "columns" => columns, "rows" => body.map { |row| row.first(columns.size) } }
    end

    def of(feed)
      Array(feed.analysis&.step_result("tables"))
    end

    def described(table)
      shown = table["rows"].first(SHOWN).map { |row| table["columns"].zip(row).to_h.to_json }
      "#{table['name']}: #{table['columns'].join(', ')} (#{table['rows'].size} rows), such as #{shown.join(' and ')}"
    end

    def spread(table, rows)
      table["columns"].each_with_index.filter_map do |name, at|
        values = rows.map { |row| row[at] }.compact
        next if values.empty?

        numbers = values.filter_map { |value| number(value) }
        next "#{name} from #{numbers.min} to #{numbers.max}" if numbers.size == values.size

        common = values.tally.max_by(SPREAD) { |_, count| count }.map { |value, count| "#{value} (#{count})" }
        "#{name}: #{common.join(', ')}"
      end
    end

    def compute(tables, spec)
      spec = spec.to_h.transform_keys(&:to_s)
      table = tables.find { |held| held["name"].casecmp?(spec["table"].to_s) } || (tables.first if tables.one?)
      raise Refused, "no table called #{spec['table']}" if table.nil?

      op = spec["op"].to_s.downcase
      raise Refused, "op is one of #{OPS.join(', ')}" unless OPS.include?(op)

      rows = Array(spec["where"]).reduce(counted(table)) { |held, test| filtered(table, held, test) }
      matched = { "rows" => rows.size, "spread" => spread(table, rows.presence || counted(table)) }
      return { "op" => op, "value" => rows.size }.merge(matched) if op == "count"

      at = column(table, spec["column"])
      values = rows.filter_map { |row| number(row[at]) }
      raise Refused, "no numbers in #{spec['column']} among the #{rows.size} rows that matched" if values.empty?

      { "op" => op, "column" => table["columns"][at], "value" => reduced(op, values).round(2) }.merge(matched)
    end

    private

      def header_at(rows)
        head = rows.first(HEADER_WITHIN)
        widest = head.map { |row| row.compact.size }.max.to_i
        return nil if widest < 2

        head.index { |row| row.compact.size == widest }
      end

      def counted(table)
        table["rows"].reject { |row| row.compact.first.to_s.match?(TOTALLED) }
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

      def passes?(cell, how, wanted, sized: false)
        text = cell.to_s.downcase
        sought = wanted.to_s.downcase

        case how
        when "contains" then text.include?(sought)
        when "equals" then text == sought || (number(cell) && number(cell) == number(wanted))
        when "starts" then text.start_with?(sought)
        else
          held = number(cell)
          bound = number(wanted)
          held, bound = held&.abs, bound&.abs if sized
          !held.nil? && !bound.nil? && held.public_send(how, bound)
        end
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
