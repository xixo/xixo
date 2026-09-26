require "json"

Tenant.switch(Tenant.find_by!(subdomain: ENV.fetch("DELEGATION_TENANT"))) do
  held = Resource.find_by(key: "stand-in")

  case ENV.fetch("DELEGATION_STEP")
  when "forget"
    held&.destroy!
  when "due"
    held.update_columns(checked_at: (Resource::CHECKED_EVERY + 1.minute).ago)
    ScheduleChecksJob.perform_later
  when "call"
    answer = begin
      { "said" => held.invoke!("whoami", {}).to_h[:content].map { |part| part["text"] }.join }
    rescue Resource::Failed => e
      { "refused" => e.class.name, "message" => e.message }
    end
    puts JSON.generate(answer)
  when "state"
    held.reload
    puts JSON.generate(
      "checked_at" => held.checked_at&.iso8601(3),
      "needs_connect" => held.needs_connect?,
      "owner_subject" => held.owner_subject,
      "holds" => held.credentials.to_h.keys.sort,
      "expires_at" => held.credentials.to_h.dig("upstream", "expires_at")
    )
  end
end
