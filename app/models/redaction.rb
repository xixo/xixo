module Redaction
  MARK = "[redacted]".freeze
  USERINFO = %r{(?<scheme>\b[a-z][a-z0-9+.\-]*://)[^/\s?#"'<>]*@}i
  CREDENTIAL = /
    (?<lead>[?&;](?:[^=&#\s"'<>]*?(?:token|key|sig|secret|passw|pwd|credential|auth|session|code)[^=&#\s"'<>]*)=)
    [^&#\s"'<>]+
  /xi

  module Message
    def initialize(message = nil)
      super(message.is_a?(String) ? Redaction.scrub(message) : message)
    end
  end

  def self.scrub(value)
    case value
    when String
      value.gsub(USERINFO, '\k<scheme>').gsub(CREDENTIAL, "\\k<lead>#{MARK}")
    when Array then value.map { |held| scrub(held) }
    when Hash then value.transform_values { |held| scrub(held) }
    else value
    end
  end
end
