class ForgetProofMarksJob < ApplicationJob
  queue_as :sync

  def perform
    ProofMark.expired.in_batches(of: 5_000).delete_all
  end
end
