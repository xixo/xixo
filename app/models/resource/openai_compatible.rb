require "net/http"
require "json"

class Resource
  class OpenaiCompatible < Resource
    include Draining
    include Relaying

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
    MAX_BYTES = 16.megabytes
    IMAGE_TYPE = "image/jpeg"
    JSON_SYSTEM = "Respond with valid JSON only. No markdown, no explanation."
    AGENT_ROLE = "agent"
    TOOL_ROLES = [ AGENT_ROLE ].freeze
    EMBEDDING_ROLE = "embedding"
    TRANSCRIPTION_ROLE = "transcription"
    VISION_ROLE = "vision"
    SEES = "vision"
    SIGHTED = [ %r{(\A|/)gemma-?3}i, /qwen(2\.5|3)-?vl/i, /minicpm-v/i, %r{(\A|/)llava}i, /llama-?3\.2-vision/i ].freeze
    STUDIO_KINDS = { "vlm" => %w[completion vision], "llm" => %w[completion], "embeddings" => %w[embedding] }.freeze
    TRANSCRIBE_TIMEOUT = 900
    HEARD_TYPE = "audio/wav"
    SAMPLE_RATE = 16_000
    EFFORTS = %w[none minimal low medium high].freeze
    AS_IT_LIKES = "model".freeze
    ASKING = "Represent this sentence for searching relevant passages: ".freeze
    KNOWN_PREFIXES = [
      [ /nomic-embed/, { "query" => "search_query: ", "document" => "search_document: " } ],
      [ /(\A|[^a-z])e5([^a-z]|\z)/, { "query" => "query: ", "document" => "passage: " } ],
      [ /mxbai-embed|bge-[a-z]+-en|snowflake-arctic-embed/, { "query" => ASKING, "document" => "" } ]
    ].freeze
    EMBED_PROBE = "an invoice from acme for four thousand two hundred dollars".freeze
    MAX_EMBED = 8_000
    CHAIN_TIMEOUT = 120
    # A thinking model spends the budget reasoning before it emits anything. At 1024 it
    # runs out mid-thought and answers with neither content nor a tool call.
    AGENT_MAX_TOKENS = 8192
    AGENT_CONTEXT = 16_384
    CHAIN_SYSTEM = "You have tools. Call one rather than answering from memory."
    CHAIN_ASK = "Search the catalog for invoices, then tell me what you found."
    CHAIN_RESULT = { count: 1, feeds: [ { id: "1", type: "xixo:file", title: "acme.pdf" } ] }.to_json
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

    def self.routable?
      true
    end

    def self.address_path
      "/v1"
    end

    def self.attaching
      {
        label: "A model backend",
        blurb: "Anything speaking the OpenAI chat API — ollama, LM Studio, llama.cpp, vLLM, " \
               "or a hosted one. Name a model for each role you want it to serve.",
        names: "A name for it",
        fields: [
          field("base_url", "Base URL", required: true, placeholder: "http://127.0.0.1:11434/v1"),
          field("models.default", "Model",
                help: "The model for every role below that is left blank. Images go to it only when its " \
                      "server says it reads them."),
          field("models.fast", "Fast model", help: "Short summaries and titles."),
          field("models.smart", "Smart model", help: "Longer reasoning."),
          field("models.vision", "Vision model",
                help: "What describes an image. It has to read images, as gemma3:4b does. " \
                      "Left blank, xixo picks one the backend serves when its server says which can, or " \
                      "uses the Model above when its server says it reads them."),
          field("models.agent", "Agent model", help: "What a feed drives. It has to call tools."),
          field("models.embedding", "Embedding model",
                help: "What search compares meaning with. Its vectors have to be the width " \
                      "the index was built for."),
          field("models.transcription", "Transcription model",
                help: "What turns speech into text, through /audio/transcriptions. whisper.cpp's server, " \
                      "speaches, and OpenAI's whisper-1 all answer there."),
          field("embedding_prefixes.query", "Query prefix",
                help: "Put before a search when it is embedded. Left off, xixo uses what nomic-embed-text, " \
                      "e5, mxbai and bge were trained with, and nothing for any other model."),
          field("embedding_prefixes.document", "Document prefix",
                help: "Put before what is catalogued when it is embedded. Left off, as above."),
          field("routine_effort", "Effort on routine work", kind: "choice", value: "",
                options: [ { value: "", label: "As the model likes" } ] +
                         EFFORTS.map { |effort| { value: effort, label: effort } },
                help: "How hard a reasoning model thinks while filing what arrives. Sent as reasoning_effort. " \
                      "Ollama takes none, and OpenAI minimal or low."),
          field("ask_effort", "Effort on questions", kind: "choice", value: "",
                options: [ { value: "", label: "none" } ] +
                         (EFFORTS - [ "none" ]).map { |effort| { value: effort, label: effort } } +
                         [ { value: AS_IT_LIKES, label: "As the model likes" } ],
                help: "How hard a reasoning model thinks before it answers a question. Sent as reasoning_effort. " \
                      "Left at none, it answers without thinking, several times sooner."),
          field("time_allowed", "Time per ask", kind: "integer",
                help: "Minutes an ask answered by this backend starts with when its item sets no timeout. " \
                      "An agent asks for more as it needs it. Left off, two minutes."),
          field("api_key", "API key", secret: true, help: "Left off where the backend wants none.")
        ]
      }
    end

    def self.command_schema
      { models: {} }
    end

    def self.permitted_origins
      PublicAddress.origins(ENV.fetch("XIXO_INFERENCE_ORIGINS", ""))
    end

    validate :it_names_an_endpoint
    validate :its_routine_effort_is_known
    validate :its_ask_effort_is_known

    after_update :forget_vectors!, if: :embedding_signature_changed?

    def self.prefixes_for(details)
      held = details.to_h
      given = held["embedding_prefixes"].to_h.slice("query", "document").compact_blank
      return given if given.any?

      model = held.dig("models", EMBEDDING_ROLE).to_s
      KNOWN_PREFIXES.find { |pattern, _| model.match?(pattern) }&.last || {}
    end

    def self.signature_for(details)
      model = details.to_h.dig("models", EMBEDDING_ROLE)
      return nil if model.blank?

      Digest::SHA256.hexdigest([ model, prefixes_for(details) ].to_json).first(16)
    end

    def embedding_signature
      self.class.signature_for(details)
    end

    def embedding_prefix(as)
      self.class.prefixes_for(details)[as.to_s].to_s
    end

    def vectors_current?
      details.to_h["embedded_with"] == embedding_signature
    end

    def forget_vectors!
      Feed.where.not(embedded_at: nil).update_all(embedded_at: nil)
      Passage.where.not(embedded_at: nil).update_all(embedded_at: nil)
      update_column(:details, details.merge("embedded_with" => embedding_signature))
    end

    def models
      details.fetch("models", {})
    end

    def serves_role?(role)
      return serves_vision? if role.to_s == VISION_ROLE
      return true if models.key?(role.to_s)

      models.key?(DEFAULT_ROLE)
    end

    def serves_vision?
      return !blind?(models[VISION_ROLE]) if models.key?(VISION_ROLE)

      models.key?(DEFAULT_ROLE) && sees?(models[DEFAULT_ROLE])
    end

    def surely_sees?
      serves_vision? && sees?(model_for(VISION_ROLE))
    end

    def sees?(model)
      capabilities_known(model).to_a.include?(SEES)
    end

    def blind?(model)
      held = capabilities_known(model)
      !held.nil? && !held.include?(SEES)
    end

    def model_capabilities
      details.to_h["model_capabilities"].to_h
    end

    def seeing_models
      model_capabilities.select { |_, can| Array(can).include?(SEES) }.keys.map { |name| name.delete_suffix(":latest") }
    end

    def sight_said
      chatting = models.except(TRANSCRIPTION_ROLE, EMBEDDING_ROLE)
      return nil if chatting.empty?

      seeing = chatting[VISION_ROLE]
      fallback = chatting[DEFAULT_ROLE]
      return "#{seeing} reads them." if seeing && sees?(seeing)
      return "None are described. #{seeing} cannot read images. #{set_vision}" if seeing && blind?(seeing)
      return "#{seeing} gets them. Its server does not say whether it reads images." if seeing
      return "None are described. #{set_vision}" if fallback.nil?
      return "The default model, #{fallback}, reads them, since no vision model is set." if sees?(fallback)
      return "None are described. The default model, #{fallback}, cannot read images. #{set_vision}" if blind?(fallback)

      "None are described. Its server does not say whether the default model, #{fallback}, reads images. #{set_vision}"
    end

    def set_vision
      offered = seeing_models.first(3)
      return "Set the Vision model to one that reads images, such as gemma3:4b." if offered.empty?

      "Set the Vision model to one that reads images: #{offered.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')}."
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
      return configured_url if relayed_by

      permitted!(reached(configured_url))
    end

    def check!
      answers!

      TOOL_ROLES.select { |role| models.key?(role) }.map { |role| model_for(role) }.uniq.each do |model|
        chains!(model)
        roomy!(model)
      end
      embeds! if models.key?(EMBEDDING_ROLE)
      transcribes! if models.key?(TRANSCRIPTION_ROLE)

      true
    end

    def answers!
      pick_default! if models.empty?

      wanted = models.except(TRANSCRIPTION_ROLE).values.uniq
      return true if wanted.empty?

      served = model_names

      missing = wanted.reject { |name| served.include?(name) || served.include?("#{name}:latest") }

      if missing.any?
        raise Resource::Unusable,
              "#{key}: #{base_url} does not serve #{missing.join(', ')} — it serves #{served.first(8).join(', ').presence || 'nothing'}"
      end

      sight!(served)
      true
    end

    def sight!(served = model_names)
      asked = models.key?(VISION_ROLE) ? [] : served.reject { |name| name.match?(NOT_FOR_CHAT) }
      named = (models.except(TRANSCRIPTION_ROLE, EMBEDDING_ROLE).values + asked).uniq
      known = named.index_with { |name| capabilities_of(name) }.compact
      return if known.empty?

      remember_capabilities!(known)
      return pick_vision!(known) unless models.key?(VISION_ROLE)
      return unless blind?(models[VISION_ROLE])

      raise Resource::Unusable, "#{key}: #{models[VISION_ROLE]} cannot read images. #{set_vision}"
    end

    def pick_vision!(known)
      sighted = known.select { |_, can| can.include?(SEES) }.keys
      chosen = SIGHTED.lazy.filter_map { |pattern| sighted.find { |name| name.match?(pattern) } }.first
      return if chosen.nil?

      update!(details: details.merge("models" => models.merge(VISION_ROLE => chosen.delete_suffix(":latest"))))
    end

    NOT_FOR_CHAT = /embed|whisper|rerank|tts/i

    def pick_default!
      chat = model_names.find { |name| !name.match?(NOT_FOR_CHAT) }
      raise Resource::Unusable, "#{name} answers, but it has no model to answer with. Download one in it, then check again" if chat.nil?

      update!(details: details.merge("models" => { DEFAULT_ROLE => chat }))
    end

    def probes?
      TOOL_ROLES.any? { |role| models.key?(role) } || models.key?(EMBEDDING_ROLE) || models.key?(TRANSCRIPTION_ROLE)
    end

    def transcribes!
      transcribe(self.class.silence)
      true
    end

    def transcribe(audio)
      model = model_for(TRANSCRIPTION_ROLE)
      fields = [
        [ "file", StringIO.new(audio.to_s.b), { filename: "heard.wav", content_type: HEARD_TYPE } ],
        [ "model", model ],
        [ "response_format", "verbose_json" ]
      ]

      lines(answer(dial("/audio/transcriptions"), TRANSCRIBE_TIMEOUT) { |uri| form(uri, fields) })
    end

    def self.silence(seconds = 1)
      samples = SAMPLE_RATE * seconds
      data = "\0".b * (samples * 2)

      [ "RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16,
        "data", data.bytesize ].pack("a4Va4a4VvvVVvva4V") + data
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
            "name a model that matches, or set XIXO_EMBEDDING_DIMENSIONS to #{vector.length} and " \
            "let the index rebuild itself"
    end

    def embed(texts, as: :document)
      prefix = embedding_prefix(as)
      wanted = Array(texts).map { |text| "#{prefix}#{scrub(text)}".truncate(MAX_EMBED) }
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

    def ask_effort
      held = details.to_h["ask_effort"].presence || "none"
      held == AS_IT_LIKES ? nil : held
    end

    def effort_for(role)
      role.to_s == AGENT_ROLE ? ask_effort : routine_effort
    end

    def time_allowed
      minutes = details.to_h["time_allowed"].to_i
      minutes.clamp(1, Feed::MAX_TIMEOUT.in_minutes.to_i).minutes if minutes.positive?
    end

    def converse(messages:, tools: [], role: AGENT_ROLE, analysis: nil, turn: 1, effort: nil)
      model = model_for(role)
      last = messages.last.to_h
      asked = (last[:content] || last["content"] || last[:name] || last["name"]).to_s.presence || "(tool result)"
      request = scrub(asked).truncate(MAX_PROMPT)
      started = Time.current

      begin
        message = streamed("/chat/completions", {
          model: model, stream: true, max_tokens: agent_max_tokens, temperature: temperature,
          messages: messages, tools: tools, reasoning_effort: effort
        }.compact_blank, timeout: read_timeout)
      rescue StandardError => e
        noted(analysis, role: role, model: model, number: turn, request: request,
              started_at: started, error: { "class" => e.class.name, "message" => e.message.truncate(500) })
        raise
      end

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

    def summarize(prompt, role:, analysis: nil, images: [], temperature: nil, schema: nil)
      model = model_for(role)
      tries = attempts_for(role)
      last = nil

      tries.times do |index|
        answer = complete(prompt, model: model, role: role, analysis: analysis, attempt: index + 1, images: images,
                          temperature: temperature, effort: effort_for(role), schema: schema)
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
      def embedding_signature_changed?
        before, after = saved_change_to_details

        self.class.signature_for(before) != self.class.signature_for(after)
      end

      def it_names_an_endpoint
        errors.add(:details, "must name a base_url") if details["base_url"].blank?
      end

      def its_ask_effort_is_known
        held = details.to_h["ask_effort"].presence
        return if held.nil? || (EFFORTS + [ AS_IT_LIKES ]).include?(held)

        errors.add(:details, "ask_effort is one of #{(EFFORTS + [ AS_IT_LIKES ]).join(', ')}")
      end

      def its_routine_effort_is_known
        return if routine_effort.nil? || EFFORTS.include?(routine_effort)

        errors.add(:details, "routine_effort is one of #{EFFORTS.join(', ')}")
      end

      def capabilities_known(model)
        held = model_capabilities
        name = [ model.to_s, "#{model}:latest" ].find { |candidate| held.key?(candidate) }
        return held[name] if name

        @probed ||= {}
        return @probed[model.to_s] if @probed.key?(model.to_s)

        @probed[model.to_s] = capabilities_of(model).tap do |found|
          update_column(:details, details.merge("model_capabilities" => held.merge(model.to_s => found))) if found
        end
      end

      def remember_capabilities!(known)
        return if model_capabilities == known

        update_column(:details, details.merge("model_capabilities" => known))
      end

      def capabilities_of(model)
        shown_by_ollama(model) || listed_by_studio[model.to_s]
      end

      def shown_by_ollama(model)
        shown = answer(rooted("/api/show"), OPEN_TIMEOUT) { |held| posting(held, { model: model }) }
        held = shown["capabilities"]
        held.is_a?(Array) ? held.map(&:to_s) : nil
      rescue Resource::Unusable, Resource::Failed, URI::InvalidURIError
        nil
      end

      def listed_by_studio
        @listed_by_studio ||= begin
          listed = answer(rooted("/api/v0/models"), OPEN_TIMEOUT) { |held| Net::HTTP::Get.new(held, headers) }
          Array(listed["data"]).filter_map do |entry|
            kind = STUDIO_KINDS[entry["type"].to_s]
            [ entry["id"].to_s, (kind + Array(entry["capabilities"]).map(&:to_s)).uniq ] if kind && entry["id"].present?
          end.to_h
        rescue Resource::Unusable, Resource::Failed, URI::InvalidURIError
          {}
        end
      end

      def rooted(path)
        URI.parse("#{base_url.chomp('/').delete_suffix('/v1')}#{path}")
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

      def complete(prompt, model:, role:, analysis:, attempt:, images:, temperature: nil, effort: nil, schema: nil)
        body = scrub(prompt).truncate(MAX_PROMPT)
        started = Time.current

        begin
          content = ask(body, model, images, temperature: temperature, effort: effort, schema: schema)
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

      def ask(body, model, images, temperature: nil, effort: nil, schema: nil)
        messages = [
          { role: "system", content: JSON_SYSTEM },
          { role: "user", content: said(body, images) }
        ]

        payload = { model: model, messages: messages, stream: true,
                    max_tokens: max_tokens, temperature: temperature || self.temperature,
                    reasoning_effort: effort }.compact
        payload[:response_format] = response_format(schema) if json_mode?

        content = streamed("/chat/completions", payload,
                           timeout: images.any? ? vision_timeout : read_timeout)["content"].to_s

        raise Resource::Unusable, "#{key}: #{model} answered with nothing" if content.blank?

        without_reasoning(content)
      end

      def response_format(schema)
        return { type: "text" } if schema.nil?

        { type: "json_schema", json_schema: { name: "answer", schema: schema } }
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
        streamed("/chat/completions", {
          model: model, stream: true, max_tokens: max_tokens, temperature: temperature,
          messages: messages, tools: [ CHAIN_TOOL ]
        }, timeout: CHAIN_TIMEOUT)
      end

      def post(path, body, timeout: read_timeout)
        answer(dial(path), timeout) { |uri| posting(uri, body) }
      end

      def streamed(path, body, timeout:)
        uri = dial(path)
        gathering = Gathering.new
        response = exchange(uri, timeout, reading: gathering) { |at| posting(at, body) }
        return gathering.message if response.is_a?(Net::HTTPSuccess)

        refused!(response, uri)
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{uri.host} did not answer with JSON"
      end

      def form(uri, fields)
        Net::HTTP::Post.new(uri, headers.except("Content-Type")).tap do |request|
          request.set_form(fields, "multipart/form-data")
        end
      end

      def lines(heard)
        segments = Array(heard["segments"])
        return heard["text"].to_s.strip if segments.empty?

        segments.filter_map do |segment|
          said = segment["text"].to_s.strip
          "[#{Time.at(segment['start'].to_f).utc.strftime('%H:%M:%S')}] #{said}" if said.present?
        end.join("\n")
      end

      def posting(uri, body)
        Net::HTTP::Post.new(uri, headers).tap { |request| request.body = JSON.generate(body) }
      end

      def headers
        base = { "Content-Type" => "application/json", "User-Agent" => "xixo" }
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
        return JSON.parse(response.body.to_s) if response.is_a?(Net::HTTPSuccess)

        refused!(response, uri)
      rescue JSON::ParserError
        raise Resource::Unusable, "#{key}: #{uri.host} did not answer with JSON"
      end

      def refused!(response, uri)
        case response
        when Net::HTTPTooManyRequests then raise Resource::Failed, "#{key}: #{uri.host} is busy"
        when Net::HTTPServerError then raise Resource::Failed, "#{key}: #{uri.host} answered #{response.code}"
        else
          raise Resource::Unusable,
                "#{key}: #{uri.host} answered #{response.code} — #{response.body.to_s.truncate(200)}"
        end
      end

      def exchange(uri, timeout, reading: nil, &build)
        machine = relayed_by
        return relayed(machine, uri, timeout, reading, build.call(uri)) if machine

        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = transported_address!(uri.hostname) if via.present?
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = timeout
        http.start do |held|
          held.request(build.call(uri)) do |response|
            gathered = reading.from(response) if reading && response.is_a?(Net::HTTPSuccess)
            drain(response, uri.host, limit: MAX_BYTES, into: gathered)
          end
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Resource::Failed, "#{key}: #{uri.host} did not answer in #{timeout}s"
      rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
        raise Resource::Failed, "#{key}: #{e.class} reaching #{uri.host}"
      end

      def through!
        relayed_by ? nil : super
      end

      def away_peer
        machine = relayed_by
        return super if machine.nil?

        machine.offline_peer(target_host)
      end

      def permitted!(target)
        return transported!(target) if via.present?

        allowed = self.class.permitted_origins

        if allowed.empty?
          raise Resource::Unusable,
                "#{key}: no inference origins are permitted — set XIXO_INFERENCE_ORIGINS"
        end

        uri = URI.parse(target.to_s)
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        return target if allowed.include?(origin)

        raise Resource::Unusable, "#{key}: #{origin} is not one of XIXO_INFERENCE_ORIGINS"
      rescue URI::InvalidURIError
        raise Resource::Unusable, "#{key}: #{target} is not a url"
      end

      def transported!(target)
        transported_address!(URI.parse(target.to_s).hostname)
        target
      end

      def transported_address!(host)
        PublicAddress.address_for!(host, through: through)
      rescue PublicAddress::Blocked => e
        raise Resource::Unusable, "#{key}: #{e.message}"
      rescue PublicAddress::Unresolvable => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end
  end
end
