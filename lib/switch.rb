module Switch
  NAMES = %w[
    URIS_ALLOW_PRIVATE_FETCH
    URIS_CHROME_NO_SANDBOX
    URIS_ITERATORS_DISABLED
    SOLID_QUEUE_IN_PUMA
    RAILS_ASSUME_SSL
    RAILS_FORCE_SSL
  ].freeze

  ON = %w[1 true yes on].freeze
  OFF = %w[0 false no off].freeze

  class Invalid < StandardError; end

  def self.on?(name, default: false)
    value = ENV[name].to_s.strip.downcase
    return default if value.empty?
    return true if ON.include?(value)
    return false if OFF.include?(value)

    raise Invalid, "#{name} is #{ENV[name].inspect}; set it to true or false"
  end

  def self.check!
    NAMES.each { |name| on?(name) }
  end
end
