module Citation
  CITED = /\[feed\s*:?\s*(\d+)\]/i
  LINKED = /\[feed\s*:?\s*(\d+)\]\([^)]*\)/i
  SPOKEN = /\s*(?:\b(?:based on|from|per|in|see)\s+)?\[?feed\s*:?\s*\d+\]?/i

  def self.ids(text)
    text.to_s.scan(CITED).flatten.map(&:to_i)
  end

  def self.unlinked(text)
    text.to_s.gsub(LINKED) { "[feed #{Regexp.last_match(1)}]" }
  end

  def self.stripped(text)
    text.to_s.gsub(SPOKEN, "").squish
  end
end
