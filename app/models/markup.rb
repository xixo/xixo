module Markup
  ENTITIES = {
    "nbsp" => " ", "amp" => "&", "lt" => "<", "gt" => ">",
    "quot" => '"', "apos" => "'", "#39" => "'"
  }.freeze

  READ_AS = "headings as # lines, and each block on a line of its own".freeze

  HEADING = %r{<h([1-6])\b[^>]*>(.*?)</h\1>}mi
  BLOCK = %r{</?(?:p|div|br|li|ul|ol|tr|table|section|article|header|footer|blockquote|pre|hr|dt|dd)\b[^>]*>}i

  def self.strip(html)
    html.to_s
        .gsub(%r{<(script|style)[^>]*>.*?</\1>}mi, " ")
        .gsub(/(?:#{BLOCK}\s*)+/, "\n")
        .gsub(HEADING) { "\n\n#{'#' * Regexp.last_match(1).to_i} #{Regexp.last_match(2).gsub(/<[^>]+>/, ' ').squish}\n\n" }
        .gsub(/<[^>]+>/, " ")
        .gsub(/&(#?\w+);/i) { ENTITIES.fetch(Regexp.last_match(1).downcase, " ") }
        .gsub(/[ \t\r\v]+/, " ")
        .gsub(/ *\n */, "\n")
        .gsub(/\n{3,}/, "\n\n")
        .strip
  end
end
