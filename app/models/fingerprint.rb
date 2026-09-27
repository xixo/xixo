require "digest"

module Fingerprint
  CHUNK = 1.megabyte

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
end
