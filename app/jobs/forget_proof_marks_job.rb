class ForgetProofMarksJob < ApplicationJob
  across_tenants!

  queue_as :sync

  def perform
    Tenant.find_each do |tenant|
      Tenant.switch(tenant) { ProofMark.expired.in_batches(of: 5_000).delete_all }
    end
  end
end
