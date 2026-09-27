require "net/http"
require "json"

class Resource
  class OpenaiCompatible < Resource
    DEFAULT_ROLE = "default"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 120
    VISION_TIMEOUT = 600
    MAX_TOKENS = 1024
    TEMPERATURE = 0.2
    JSON_ATTEMPTS = 3
    VISION_JSON_ATTEMPTS = 10
    MAX_PROMPT = 40_000
    MAX_IMAGE = 8.megabytes
    IMAGE_TYPE = "image/jpeg"
    JSON_SYSTEM = "Respond with valid JSON only. No markdown, no explanation."
    AGENT_ROLE = "agent"
    SCOUT_ROLE = "scout"
    TOOL_ROLES = [ AGENT_ROLE, SCOUT_ROLE ].freeze
    EMBEDDING_ROLE = "embedding"
    EFFORTS = %w[none minimal low medium high].freeze
    EMBED_PROBE = "an invoice from acme for four thousand two hundred dollars".freeze
    MAX_EMBED = 8_000
    CHAIN_TIMEOUT = 120
    # A thinking model spends the budget reasoning before it emits anything. At 1024 it
    # runs out mid-thought and answers with neither content nor a tool call.
    AGENT_MAX_TOKENS = 8192
    AGENT_CONTEXT = 16_384
    CHAIN_SYSTEM = "You have tools. Call one rather than answering from memory."
    CHAIN_ASK = "Search the catalog for invoices, then tell me what you found."
    CHAIN_RESULT = { count: 1, feeds: [ { id: "1", type: "uris:file", title: "acme.pdf" } ] }.to_json
    CHAIN_TOOL = {
      type: "function",
      function: {
        name: "search",
        description: "Search the catalog.",
        parameters: {
          type: "object",
          properties: { query: { type: "string", description: "Words to match." } },
          required: [ "query" ]
        }
      }
    }.freeze

    serves :inference

    def self.attaching
      {
        label: "A model backend",
        blurb: "Anything speaking the OpenAI chat API — ollama, LM Studio, llama.cpp, vLLM, " \
               "or a hosted one. Name a model for each role you want it to serve.",
        names: "A name for it",
        fields: [
          field("base_url", "Base URL", required: true, placeholder: "http://127.0.0.1:11434/v1"),
          field("models.fast", "Fast model", help: "Short summaries and titles."),
          field("models.smart", "Smart model", help: "Longer reasoning."),
          field("models.vision", "Vision model", help: "Anything that has to look at an image."),
          field("models.agent", "Agent model", help: "What a feed drives. It has to call tools."),
          field("models.scout", "Scout model",
                help: "What the agent sends out to find things, in a fresh context each time. It has to " \
                      "call tools, and can be smaller. Left empty, the agent model scouts."),
          field("models.embedding", "Embedding model",
                help: "What search compares meaning with. Its vectors have to be the width " \
                      "the index was built for."),
          field("routine_effort", "Effort on routine work", kind: "choice", value: "",
                options: [ { value: "", label: "As the model likes" } ] +
                         EFFORTS.map { |effort| { value: effort, label: effort } },
                help: "How hard a reasoning model thinks while filing what arrives. Sent as reasoning_effort. " \
                      "Ollama takes none, and OpenAI minimal or low. Questions always think as the model likes."),
          field("api_key", "API key", secret: true, help: "Left off where the backend wants none.")
        ]
      }
    end

    def self.command_schema
      { models: {} }
    end

    def self.permitted_origins
      PublicAddress.origins(ENV.fetch("URIS_INFERENCE_ORIGINS", ""))
    end

    validate :it_names_an_endpoint
    validate :its_routine_effort_is_known

    after_update :reconsider_every_vector, if: :embedding_model_changed?

    def models
      details.fetch("models", {})
    end

    def serves_role?(role)
      models.key?(role.to_s) || models.key?(DEFAULT_ROLE)
    end

    def declares_role?(role)
      models.key?(role.to_s)
    end

    def model_for(role)
      models[role.to_s] || models[DEFAULT_ROLE] ||
        raise(Resource::Unusable, "#{key} serves no model for #{role}")
    end

    def read_timeout = details.fetch("read_timeout", READ_TIMEOUT).to_i
    def vision_timeout = details.fetch("read_timeout", VISION_TIMEOUT).to_i
    def max_tokens = details.fetch("max_tokens", MAX_TOKENS).to_i
    def temperature = details.fetch("temperature", TEMPERATURE).to_f
    def json_mode? = details.fetch("json_mode", true)

    def base_url
      permitted!(via.present? ? via.reach!(configured_url) : configured_url)
    end

    def check!
      served = model_names
      wanted = models.values.uniq
      missing = wanted.reject { |name| served.include?(name) || served.include?("#{name}:latest") }

      if wanted.empty?
        raise Resource::Unusable, "#{key}: no models are declared — set details.models"
      end

      if missing.any?
        raise Resource::Unusable,
              "#{key}: #{base_url} does not serve #{missing.join(', ')} — it serves #{served.first(8).join(', ').presence || 'nothing'}"
      end

      TOOL_ROLES.select { |role| models.key?(role) }.map { |role| model_for(role) }.uniq.each do |model|
        chains!(model)
        roomy!(model)
      end
      embeds! if models.key?(EMBEDDING_ROLE)

      true
    end

    def roomy!(model = model_for(AGENT_ROLE))
      loaded = loaded_context(model)
      return true if loaded.nil? || loaded >= AGENT_CONTEXT

      raise Resource::Unusable,
            "#{key}: #{model} is loaded with a #{loaded}-token context. An agent's transcript outgrows " \
            "that within a few turns and the model forgets its instructions and the question — give it " \
            "#{AGENT_CONTEXT} or more, as OLLAMA_CONTEXT_LENGTH=32768 for ollama, then restart it"
    end

    def embeds!
      model = model_for(EMBEDDING_ROLE)
      vector = embed([ EMBED_PROBE ]).first
      wanted = Embedding.dimensions

      raise Resource::Unusable, "#{key}: #{model} answered with no vector" if vector.blank?
      return true if vector.length == wanted

      raise Resource::Unusable,
            "#{key}: #{model} returns #{vector.length} dimensions and the index holds #{wanted} — " \
            "name a model that matches, or set URIS_EMBEDDING_DIMENSIONS to #{vector.length} and " \
            "let the index rebuild itself"
    end

    def embed(texts)
      wanted = Array(texts).map { |text| scrub(text).truncate(MAX_EMBED) }
      return [] if wanted.empty?

      model = model_for(EMBEDDING_ROLE)
      answered = post("/embeddings", { model: model, input: wanted }, timeout: read_timeout)
      vectors = Array(answered["data"]).sort_by { |entry| entry["index"].to_i }
                                       .map { |entry| Array(entry["embedding"]).map(&:to_f) }

      if vectors.length != wanted.length
        raise Resource::Unusable,
              "#{key}: #{model} answered with #{vectors.length} vectors for #{wanted.length} texts"
      end

      vectors
    end

    # Serving a model is not the same as being able to drive a tool loop. Two turns,
    # because one proves nothing: a model can answer the first call correctly and then
    # break the moment a tool result is in the history, which is every turn after it.
    #
    def chains!(model = model_for(AGENT_ROLE))
      messages = [ { role: "system", content: CHAIN_SYSTEM }, { role: "user", content: CHAIN_ASK } ]

      first = turn(model, messages)
      call = first["tool_calls"]&.first

      unless call
        raise Resource::Unusable,
              "#{key}: #{model} is meant to call tools but answered without a tool call — " \
              "#{first['content'].to_s.squish.truncate(120)}"
      end

      messages << first
      messages << { role: "tool", tool_call_id: call["id"].to_s, name: CHAIN_TOOL.dig(:function, :name),
                    content: CHAIN_RESULT }

      second = turn(model, messages)
      return true if second["tool_calls"].present?

      said = second["content"].to_s.squish
      return true unless said.include?('"name"') || said.start_with?("[{", "{\"")

      raise Resource::Unusable,
            "#{key}: #{model} wrote its second call as text instead of a tool call, so it " \
            "cannot drive a loop — #{said.truncate(120)}"
    end

    # One turn of a tool loop. The caller owns the messages and decides what to do with a
    # tool call, because the loop is ours: a model emits a request to run something, never
    # runs it. json_mode is deliberately not set here — response_format and tools fight,
    # and a model forced into a JSON object cannot emit a tool call.
    def routine_effort
      details.to_h["routine_effort"].presence
    end

    def converse(messages:, tools: [], role: AGENT_ROLE, analysis: nil, turn: 1, effort: nil)
      model = model_for(role)
      last = messages.last.to_h
      asked = (last[:content] || last["content"] || last[:name] || last["name"]).to_s.presence || "(tool result)"
      request = scrub(asked).truncate(MAX_PROMPT)
      started = Time.current

      begin
        answered = post("/chat/completions", {
          model: model, stream: false, max_tokens: agent_max_tokens, temperature: temperature,
          messages: messages, tools: tools, reasoning_effort: effort
        }.compact_blank, timeout: read_timeout)
      rescue StandardError => e
        noted(analysis, role: role, model: model, number: turn, request: request,
              started_at: started, error: { "class" => e.class.name, "message" => e.message.truncate(500) })
        raise
      end

      message = answered.dig("choices", 0, "message") || {}
      noted(analysis, role: role, model: model, number: turn, request: request,
            started_at: started, content: recorded(message),
            calls: Array(message["tool_calls"]).filter_map { |call| call.dig("function", "name") })

      if message["content"].blank? && message["tool_calls"].blank?
        raise Resource::Unusable,
              "#{key}: #{model} answered with neither content nor a tool call — it likely spent " \
              "the #{agent_max_tokens} token budget reasoning"
      end

      message
    end

    def agent_max_tokens = details.fetch("agent_max_tokens", AGENT_MAX_TOKENS).to_i

    # Thinking models put their reasoning somewhere other than content, and it is the most
    # useful thing in the row when a turn goes wrong.
    def recorded(message)
      said = message["content"].to_s
      calls = Array(message["tool_calls"]).filter_map { |call| call.dig("function", "name") }
      thought = (message["reasoning"] || message["reasoning_content"]).to_s

      [ said.presence, ("called #{calls.join(', ')}" if calls.any?),
        ("thinking: #{thought.squish.truncate(2000)}" if thought.present?) ].compact.join("\n\n")
    end

    def noted(analysis, **held)
      return if analysis.nil?

      analysis.turn!(resource: self, **held)
    rescue StandardError => e
      Rails.logger.warn "#{key}: a turn could not be recorded — #{e.message}"
    end

    def summarize(prompt, role:, analysis: nil, images: [], temperature: nil)
      model = model_for(role)
      tries = attempts_for(role)
      last = nil

      tries.times do |index|
        answer = complete(prompt, model: model, role: role, analysis: analysis,
                          attempt: index + 1, images: images, temperature: temperature)
        parsed = self.class.extract_json(answer)

        return parsed if parsed.is_a?(Hash) && parsed.present?

        last = answer
      end

      raise Resource::Unusable,
            "#{key}: #{model} did not answer with JSON in #{tries} tries — #{last.to_s.truncate(200)}"
    end

    def attempts_for(role)
      role.to_s == "vision" ? VISION_JSON_ATTEMPTS : JSON_ATTEMPTS
    end

    def command_models
      { "base_url" => base_url, "declared" => models, "available" => model_names }
    end

    def self.extract_json(text)
      body = text.to_s
      fenced = body[/```(?:json)?\s*(\{.*?\})\s*```/m, 1]

      ([ fenced ].compact + objects(body)).each do |candidate|
        parsed = begin
          JSON.parse(candidate)
        rescue JSON::ParserError
          nil
        end

        return parsed if parsed.is_a?(Hash)
      end

      nil
    end

    def self.objects(body)
      found = []
      depth = 0
      start = nil
      quoted = false
      escaped = false

      body.each_char.with_index do |char, index|
        if quoted
          if escaped then escaped = false
          elsif char == "\\" then escaped = true
          elsif char == '"' then quoted = false
          end
          next
        end

        case char
        when '"' then quoted = true
        when "{"
          start = index if depth.zero?
          depth += 1
        when "}"
          next if depth.zero?

          depth -= 1
          found << body[start..index] if depth.zero?
        end
      end

      found
    end

    private

      def configured_url = details["base_url"].to_s

      # Two models do not share a vector space, so a catalogue half embedded by each is a
      # catalogue that answers neither well. Changing the model clears every stamp, and the
      # sweep does the rest.
      def embedding_model_changed?
        before, after = saved_change_to_details

        before.to_h.dig("models", EMBEDDING_ROLE) != after.to_h.dig("models", EMBEDDING_ROLE)
      end

      def reconsider_every_vector
        Feed.where.not(embedded_at: nil).update_all(embedded_at: nil)
      end

      def it_names_an_endpoint
        errors.add(:details, "must name a base_url") if details["base_url"].blank?
      end

      def its_routine_effort_is_known
        return if routine_effort.nil? || EFFORTS.include?(routine_effort)

        errors.add(:details, "routine_effort is one of #{EFFORTS.join(', ')}")
      end

      def loaded_context(model)
        uri = URI.parse("#{base_url.chomp('/').delete_suffix('/v1')}/api/ps")
        running = answer(uri, OPEN_TIMEOUT) { |held| Net::HTTP::Get.new(held, headers) }

        found = Array(running["models"]).find do |entry|
          [ entry["name"], entry["model"] ].any? { |name| name == model || name == "#{model}:latest" }
        end

        found&.dig("context_length")&.to_i&.nonzero?
      rescue Resource::Unusable, Resource::Failed, URI::InvalidURIError
        nil
      end

      def model_names
        get("/models").fetch("data", []).filter_map { |entry| entry["id"] }
      end

      def complete(prompt, model:, role:, analysis:, attempt:, images:, temperature: nil)
        body = scrub(prompt).truncate(MAX_PROMPT)
        started = Time.current

        begin
          content = ask(body, model, images, temperature: temperature)
        rescue StandardError => e
          noted(analysis, role: role, model: model, number: attempt, request: body,
                started_at: started,
                error: { "class" => e.class.name, "message" => e.message.truncate(500) })
          raise
        end

        noted(analysis, role: role, model: model, number: attempt, request: body,
              started_at: started, content: content)
        content
      end

      def ask(body, model, images, temperature: nil)
        messages = [
          { role: "system", content: JSON_SYSTEM },
          { role: "user", content: said(body, images) }
        ]

        payload = { model: model, messages: messages, stream: false,
                    max_tokens: max_tokens, temperature: temperature || self.temperature }
        payload[:response_format] = { type: "json_object" } if json_mode?

        answered = post("/chat/completions", payload,
                        timeout: images.any? ? vision_timeout : read_timeout)
        content = answered.dig("choices", 0, "message", "content").to_s

        raise Resource::Unusable, "#{key}: #{model} answered with nothing" if content.blank?

        without_reasoning(content)
      end

      def said(body, images)
        return body if images.empty?

        [ { type: "text", text: body } ] +
          images.map { |bytes| { type: "image_url", image_url: { url: data_uri(bytes) } } }
      end

      def data_uri(bytes)
        if bytes.bytesize > MAX_IMAGE
          raise Resource::Unusable,
                "#{key}: an image of #{bytes.bytesize} bytes is more than #{MAX_IMAGE} to send"
        end

        "data:#{IMAGE_TYPE};base64,#{Base64.strict_encode64(bytes)}"
      end

      def without_reasoning(text)
        text.gsub(%r{<think>.*?</think>}m, "").strip
      end

      def scrub(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").delete("\u0000")
      end

      def get(path)
        answer(dial(path), read_timeout) { |uri| Net::HTTP::Get.new(uri, headers) }
      end

      def turn(model, messages)
        answered = post("/chat/completions", {
          model: model, stream: false, max_tokens: max_tokens, temperature: temperature,
          messages: messages, tools: [ CHAIN_TOOL ]
        }, timeout: CHAIN_TIMEOUT)

        answered.dig("choices", 0, "message") || {}
      end

      def post(path, body, timeout: read_timeout)
        answer(dial(path), timeout) do |uri|
          request = Net::HTTP::Post.new(uri, headers)
          request.body = JSON.generate(body)
          request
        end
      end

      def headers
        base = { "Content-Type" => "application/json", "User-Agent" => "uris" }
        token = credentials["api_key"].presence

        token ? base.merge("Authorization" => "Bearer #{token}") : base
      end

      def dial(path)
        uri = URI.parse("#{base_url.chomp('/')}/#{path.delete_prefix('/')}")
        raise Resource::Unusable, "#{key}: #{base_url} is not an http url" unless uri.is_a?(URI::HTTP)

        uri
      end

      def answer(uri, timeout, &build)
        response = exchange(uri, timeout, &build)

        case response
        when Net::HTTPSuccess then JSON.parse(response.body.to_s)
        when Net::HTTPTooManyRequests then raise Resource::Failed, "#{key}: #{uri.host} is busy"
        when Net::HTTPServerError then raise Resource::Failed, "#{key}: #{uri.host} answered #{response.code}"
        else
          raise Resource::Unusable,
                "#{key}: #{uri.host} answered #{response.code} — #{response.body.to_s.truncate(200)}"
        end
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{uri.host} did not answer with JSON"
      end

      def exchange(uri, timeout, &build)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: timeout) do |http|
          http.request(build.call(uri))
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Resource::Failed, "#{key}: #{uri.host} did not answer in #{timeout}s"
      rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching #{uri.host}"
      end

      def permitted!(target)
        return target if via.present?

        allowed = self.class.permitted_origins

        if allowed.empty?
          raise Resource::Unusable,
                "#{key}: no inference origins are permitted — set URIS_INFERENCE_ORIGINS"
        end

        uri = URI.parse(target.to_s)
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        return target if allowed.include?(origin)

        raise Resource::Unusable, "#{key}: #{origin} is not one of URIS_INFERENCE_ORIGINS"
      rescue URI::InvalidURIError
        raise Resource::Unusable, "#{key}: #{target} is not a url"
      end
  end
end
