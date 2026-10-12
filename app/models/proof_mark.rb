class ProofMark < ApplicationRecord
  self.primary_key = "digest"

  scope :expired, -> { where(expires_at: ...Time.current) }

  class << self
    def first?(key, expires_in:)
      now = Time.current
      inserted = connection.exec_query(<<~SQL.squish, "ProofMark", [ digest_for(key), now + expires_in.to_i, now ])
        INSERT INTO proof_marks (digest, expires_at) VALUES ($1, $2)
        ON CONFLICT (digest) DO UPDATE SET expires_at = EXCLUDED.expires_at
        WHERE proof_marks.expires_at < $3
        RETURNING digest
      SQL

      inserted.rows.any?
    end

    def digest_for(key)
      Digest::SHA256.hexdigest(key.to_s)
    end
  end
end
