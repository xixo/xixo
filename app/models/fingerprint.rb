require "digest"

module Fingerprint
  CHUNK = 1.megabyte
  EMPTY = Digest::SHA256.hexdigest("").freeze

  def self.of(body)
    return Digest::SHA256.hexdigest(body.to_s) unless body.respond_to?(:read)

    sha = Digest::SHA256.new
    body.rewind if body.respond_to?(:rewind)

    while (chunk = body.read(CHUNK))
      sha << chunk
    end

    body.rewind if body.respond_to?(:rewind)
    sha.hexdigest
  end

  def self.lock!(digest)
    connection = ActiveRecord::Base.connection
    raise ArgumentError, "a fingerprint is only locked inside a transaction" unless connection.transaction_open?

    connection.execute(ActiveRecord::Base.sanitize_sql_array(
      [ "SELECT pg_advisory_xact_lock(hashtext(?))", "#{Current.tenant&.id}:#{digest}" ]
    ))
  end
end
