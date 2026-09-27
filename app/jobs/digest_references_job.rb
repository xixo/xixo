class DigestReferencesJob < ApplicationJob
  queue_as :analysis
  across_tenants!

  BATCH = 20

  def perform
    Tenant.find_each { |tenant| Tenant.switch(tenant) { sweep(tenant) } }
  end

  private

    def sweep(tenant)
      Reference.originals.where(digest: nil, gone_at: nil).order(:updated_at, :id).limit(BATCH).each do |reference|
        digest(reference, tenant)
      end
    end

    def digest(reference, tenant)
      io = reference.download
      reference.update_columns(digest: Fingerprint.of(io))
    rescue Resource::Failed, Resource::Unusable, SystemCallError, IOError => e
      reference.update_columns(updated_at: Time.current)
      Rails.logger.warn("#{tenant.subdomain} could not fingerprint reference #{reference.id}: #{e.class}: #{e.message.truncate(200)}")
    ensure
      io.close if io.respond_to?(:close)
    end
end
