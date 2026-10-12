require "test_helper"

class ProofMarkTest < ActiveSupport::TestCase
  test "a proof is first once until it expires" do
    assert ProofMark.first?("thumb:one", expires_in: 120)
    assert_not ProofMark.first?("thumb:one", expires_in: 120)
    assert ProofMark.first?("thumb:two", expires_in: 120)
  end

  test "a proof seen long enough ago counts as first again" do
    ProofMark.create!(digest: ProofMark.digest_for("thumb:old"), expires_at: 1.minute.ago)

    assert ProofMark.first?("thumb:old", expires_in: 120)
    assert_not ProofMark.first?("thumb:old", expires_in: 120)
  end

  test "only one of two processes racing on a proof sees it first" do
    key = "thumb:race-#{SecureRandom.hex(4)}"
    gate = Queue.new
    answers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          ProofMark.first?(key, expires_in: 120)
        end
      end
    end

    2.times { gate << true }

    assert_equal [ false, true ], answers.map(&:value).sort_by { |seen| seen ? 1 : 0 }
  ensure
    ProofMark.where(digest: ProofMark.digest_for(key)).delete_all
  end

  test "the sweep forgets only expired proofs" do
    ProofMark.create!(digest: "gone", expires_at: 1.minute.ago)
    ProofMark.create!(digest: "kept", expires_at: 1.minute.from_now)

    ForgetProofMarksJob.perform_now

    assert_equal [ "kept" ], ProofMark.where(digest: %w[gone kept]).pluck(:digest)
  end
end
