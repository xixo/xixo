module Quoted
  ATTRIBUTION = /\AOn\b.{4,300}\bwrote:\s*\z/m
  ORIGINAL = /\A-{2,}\s*(Original Message|Forwarded message)\s*-{2,}\s*\z/i
  OUTLOOK_FROM = /\A\*?From:\*?\s+\S/
  OUTLOOK_FIELDS = /\A\*?(Sent|Date|To|Subject|Cc):\*?\s/
  QUOTE = /\A\s*>/

  Split = Data.define(:fresh, :earlier)

  def self.split(text)
    lines = text.to_s.lines
    cut = cut_at(lines)
    return Split.new(fresh: text.to_s.strip, earlier: nil) if cut.nil?

    fresh = lines[0...cut].join.strip
    return Split.new(fresh: text.to_s.strip, earlier: nil) if fresh.empty?

    Split.new(fresh: fresh, earlier: unquoted(lines[cut..]).presence)
  end

  def self.cut_at(lines)
    lines.each_index do |index|
      line = lines[index].strip
      joined = [ line, lines[index + 1].to_s.strip ].join(" ")

      return index if line.start_with?("On ") && (line.match?(ATTRIBUTION) || joined.match?(ATTRIBUTION))
      return index if line.match?(ORIGINAL)
      return index if outlook_header?(lines, index)
      return index if quoted_to_the_end?(lines, index)
    end

    nil
  end

  def self.outlook_header?(lines, index)
    return false unless lines[index].strip.match?(OUTLOOK_FROM)

    lines[(index + 1)..(index + 4)].to_a.count { |line| line.strip.match?(OUTLOOK_FIELDS) } >= 2
  end

  def self.quoted_to_the_end?(lines, index)
    return false unless lines[index].match?(QUOTE)

    lines[index..].all? { |line| line.strip.empty? || line.match?(QUOTE) }
  end

  def self.unquoted(lines)
    lines.map { |line| line.sub(/\A\s*> ?/, "") }.join.strip
  end
end
