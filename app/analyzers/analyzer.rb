module Analyzer
  class Failed < StandardError
    prepend Redaction::Message
  end

  class Waiting < StandardError
    prepend Redaction::Message

    attr_reader :kind, :machine

    def initialize(message = nil, kind: nil, machine: nil)
      super(message)
      @kind = kind
      @machine = machine
    end
  end

  class Unanswered < Waiting; end

  MODELS = "models".freeze
  PROMPTS_CHANGED_AT = Time.utc(2026, 9, 7).freeze

  def self.inferring(resource)
    yield
  rescue Resource::Offline => e
    raise Waiting.new(e.message, kind: MODELS, machine: serving(resource))
  rescue Resource::Unreachable => e
    raise Unanswered.new(e.message, kind: MODELS, machine: serving(resource))
  end

  def self.serving(resource)
    return nil if resource.nil?

    resource.try(:relayed_by) || resource
  end

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
