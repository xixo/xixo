class DigestReferencesJob < ApplicationJob
  queue_as :analysis
  across_tenants!

  BATCH = 20
  BUDGET = 45.seconds

  limits_concurrency to: 1, key: ->(*) { "digest_references" }, duration: 10.minutes

  def perform
    Tenant.find_each { |tenant| Tenant.switch(tenant) { sweep } }
  end

  private

    def sweep
      stop = BUDGET.from_now

      Reference.originals.where(digest: nil, gone_at: nil, resource: Resource.active)
               .order(:updated_at, :id).limit(BATCH).each do |reference|
        break if Time.current > stop

        fingerprint(reference)
      end
    end

    def fingerprint(reference)
      io = reference.download
      found = Fingerprint.of(io)

      Reference.where(id: reference.id, digest: nil, version: reference.version).update_all(digest: found)
    rescue StandardError => e
      Reference.where(id: reference.id).update_all(updated_at: Time.current)
      Rails.logger.warn("#{Current.tenant.subdomain} could not fingerprint reference #{reference.id}: #{e.class}: #{e.message.truncate(200)}")
    ensure
      io.close if io.respond_to?(:close)
    end
end
