module Analyzer
  class Failed < StandardError
    prepend Redaction::Message
  end

  PROMPTS_CHANGED_AT = Time.utc(2026, 9, 7).freeze

  def self.all
    [
      Analyzer::Pdf, Analyzer::Image, Analyzer::Media, Analyzer::Page, Analyzer::Doc, Analyzer::Epub, Analyzer::Xlsx,
      Analyzer::Calendar, Analyzer::Pkpass, Analyzer::Email, Analyzer::Entry, Analyzer::Contact,
      Analyzer::Data, Analyzer::Text, Analyzer::Fallback
    ]
  end

  def self.for(feed, analysis: nil)
    class_for(feed).new(feed, analysis: analysis)
  end

  def self.class_for(feed)
    all.find { |analyzer| analyzer.handles?(feed) }
  end
end
