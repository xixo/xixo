TENANTS = [
  { subdomain: "demo",  name: "Demo items" },
  { subdomain: "acme",  name: "Acme" }
]

seeded = Tenant.declare!.presence || TENANTS.map do |attrs|
  Tenant.find_or_create_by!(subdomain: attrs[:subdomain]) { |t| t.name = attrs[:name] }
end

seeded.each do |tenant|
  Tenant.switch(tenant) do
    Resource::Database.find_or_create_by!(key: "database") do |resource|
      resource.name = "Default storage"
    end.make_default_storage!

    if (endpoint = ENV["S3_ENDPOINT"]).present?
      storage = Resource::S3.find_or_initialize_by(key: "items-#{tenant.subdomain}")
      storage.assign_attributes(
        name: "Object storage",
        details: {
          "endpoint" => endpoint,
          "region" => ENV.fetch("S3_REGION", "us-east-1")
        },
        credentials: {
          "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
          "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "urisuris")
        }
      )
      storage.save!

      begin
        storage.client.create_bucket(bucket: storage.bucket)
      rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
        nil
      rescue Seahorse::Client::NetworkingError => e
        warn "  storage unreachable (#{e.class}) — is docker compose running?"
      end
    end

    Resource::Web.find_or_create_by!(key: "web") do |resource|
      resource.name = "Snapshots"
      resource.details = {}
    end

    Resource::Places.find_or_create_by!(key: "places") do |places|
      places.name = "Places"
      places.details = { "provider" => "openstreetmap", "photos" => "true" }
    end

    Resource::Weather.find_or_create_by!(key: "weather") do |weather|
      weather.name = "Weather"
      weather.details = { "provider" => "open-meteo", "units" => "metric" }
    end

    if (endpoint = ENV["OLLAMA_URL"]).present?
      brain = Resource::OpenaiCompatible.find_or_initialize_by(key: "ollama")
      brain.assign_attributes(
        name: "Local models",
        details: {
          "base_url" => endpoint,
          "models" => {
            "fast" => ENV.fetch("OLLAMA_FAST_MODEL", "gemma3:4b"),
            "smart" => ENV.fetch("OLLAMA_SMART_MODEL", "llama3.1:8b"),
            "vision" => ENV.fetch("OLLAMA_VISION_MODEL", "gemma3:4b"),
            "agent" => ENV.fetch("OLLAMA_AGENT_MODEL", "qwen3:8b"),
            "embedding" => ENV.fetch("OLLAMA_EMBEDDING_MODEL", "nomic-embed-text")
          },
          "routine_effort" => "none"
        }
      )
      brain.save!

      held = Resource.default_inference
      brain.make_default_inference! if held.nil? || held == brain

      unless brain.check
        warn "  ollama unreachable at #{endpoint} — #{brain.check_error}"
        warn "  summaries will be skipped until it answers"
      end
    end

    # Any OpenAI-compatible server is another row, reached by its own base_url. Nothing is
    # discovered: a backend exists here because it was declared, with its models named per
    # role. LM Studio and mlx both serve models ollama's library does not carry.
    #
    #   Resource::OpenaiCompatible.create!(
    #     key: "lmstudio", name: "LM Studio",
    #     details: { "base_url" => "http://localhost:1234/v1",
    #                "models" => { "agent" => "openai/gpt-oss-20b" } })
    #
    #   Resource::OpenaiCompatible.create!(
    #     key: "mlx", name: "mlx",
    #     details: { "base_url" => "http://127.0.0.1:8082/v1",
    #                "models" => { "fast" => "mlx-community/Qwen3-8B-4bit" } })
    #
    # Each needs its origin in URIS_INFERENCE_ORIGINS. A hosted one takes an api_key in
    # credentials; one behind a transport takes a via.

    puts "seeded #{tenant.subdomain}: #{Resource.active.count} resource(s)"
  end
end
