require "socket"
require "json"
require "digest"

class FakeModelServer
  WIDTH = 768
  class << self
    def current
      @current ||= new
    end
  end

  attr_reader :port

  def initialize
    @lock = Mutex.new
    @served = []
    @answers = []
    @prompts = []
    @attachments = []
    @efforts = []
    @systems = []
    @counts = Hash.new(0)
    @authorizations = Hash.new { |hash, key| hash[key] = [] }
    @hang = 0
    @trickle = 0
    @embedded = []
    @width = WIDTH
    @vectors = {}
    @busy = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def origin
    "http://127.0.0.1:#{port}"
  end

  def base_url
    "#{origin}/v1"
  end

  def reset!
    drain!

    @lock.synchronize do
      @served = []
      @answers = []
      @prompts = []
      @attachments = []
      @efforts = []
      @systems = []
      @counts = Hash.new(0)
      @authorizations = Hash.new { |hash, key| hash[key] = [] }
      @hang = 0
      @trickle = 0
      @embedded = []
      @width = WIDTH
      @vectors = {}
      @loaded = nil
    end
    self
  end

  def loads(model, context:)
    @lock.synchronize { @loaded = { "name" => model, "model" => model, "context_length" => context } }
    self
  end

  def embeds(width: WIDTH)
    @lock.synchronize { @width = width }
    self
  end

  def embeds_as(text, vector)
    @lock.synchronize { @vectors[text.to_s] = vector }
    self
  end

  def embedded
    @lock.synchronize { @embedded.dup }
  end

  def serves(*models)
    @lock.synchronize { @served = models.flatten.map(&:to_s) }
    self
  end

  def answer(content)
    @lock.synchronize { @answers << { content: content.to_s } }
    self
  end

  def answer_json(payload)
    answer(JSON.generate(payload))
  end

  def answer_tool_call(name, arguments = {})
    @lock.synchronize do
      @answers << { tool_calls: [ { "id" => "call_#{@answers.size}", "type" => "function",
                                    "function" => { "name" => name.to_s,
                                                    "arguments" => JSON.generate(arguments) } } ] }
    end
    self
  end

  def answer_tool_calls(calls)
    @lock.synchronize do
      made = calls.each_with_index.map do |(name, arguments), index|
        { "id" => "call_#{@answers.size}_#{index}", "type" => "function",
          "function" => { "name" => name.to_s, "arguments" => JSON.generate(arguments) } }
      end

      @answers << { tool_calls: made }
    end
    self
  end

  def refuse(status, body: "")
    @lock.synchronize { @answers << { status: status, body: body } }
    self
  end

  def hang(seconds)
    @lock.synchronize { @hang = seconds }
    self
  end

  def trickle(seconds)
    @lock.synchronize { @trickle = seconds }
    self
  end

  def drain!(within: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within

    while @lock.synchronize { @busy }.positive?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  def prompts
    @lock.synchronize { @prompts.dup }
  end

  def attachments
    @lock.synchronize { @attachments.dup }
  end

  def efforts
    @lock.synchronize { @efforts.dup }
  end

  def systems
    @lock.synchronize { @systems.dup }
  end

  def count_for(path)
    @lock.synchronize { @counts[path] }
  end

  def authorizations_for(path)
    @lock.synchronize { @authorizations[path].dup }
  end

  private

    def serve
      loop do
        socket = @server.accept
        @lock.synchronize { @busy += 1 }
        Thread.new { respond(socket) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def respond(socket)
      request = socket.gets.to_s
      headers = {}

      while (line = socket.gets) && line.strip != ""
        name, value = line.split(":", 2)
        headers[name.to_s.strip.downcase] = value.to_s.strip
      end

      path = request.split(" ")[1].to_s
      length = headers["content-length"].to_i
      body = length.positive? ? socket.read(length).to_s : ""

      pause, gap = @lock.synchronize do
        @counts[path] += 1
        @authorizations[path] << headers["authorization"]
        [ @hang, @trickle ]
      end

      sleep(pause) if pause.positive?

      Array(route(path, body)).each_with_index do |part, at|
        sleep(gap) if at.positive? && gap.positive?
        socket.print(part)
        socket.flush
      end
    rescue Errno::EPIPE, IOError
      nil
    ensure
      socket.close rescue nil
      @lock.synchronize { @busy -= 1 }
    end

    def route(path, body)
      case path
      when %r{/models\z} then rendered(200, JSON.generate(models_payload))
      when %r{/chat/completions\z} then completion(body)
      when %r{/embeddings\z} then embeddings(body)
      when %r{\A/api/ps\z} then loaded_payload
      else rendered(404, "")
      end
    end

    def embeddings(body)
      wanted = Array(JSON.parse(body)["input"])
      @lock.synchronize { @embedded.concat(wanted) }

      data = wanted.each_with_index.map do |text, index|
        { "index" => index, "embedding" => vector_for(text) }
      end

      rendered(200, JSON.generate({ "object" => "list", "data" => data }))
    rescue JSON::ParserError
      rendered(400, "")
    end

    def vector_for(text)
      held, width = @lock.synchronize { [ @vectors[text.to_s], @width ] }

      return held if held

      vector = Array.new(width, 0.0)

      text.to_s.downcase.scan(/[a-z0-9]+/).each do |word|
        vector[Digest::SHA256.hexdigest(word)[0, 8].to_i(16) % width] += 1.0
      end

      vector
    end

    def loaded_payload
      held = @lock.synchronize { @loaded }
      return rendered(404, "") if held.nil?

      rendered(200, JSON.generate("models" => [ held ]))
    end

    def models_payload
      { "object" => "list", "data" => @lock.synchronize { @served }.map { |id| { "id" => id } } }
    end

    def completion(body)
      record_prompt(body)
      queued = @lock.synchronize { @answers.shift }
      return rendered(queued[:status], queued[:body]) if queued&.key?(:status)
      return streamed(queued) if streaming?(body)
      return rendered(200, JSON.generate(completion_payload(""))) if queued.nil?

      return rendered(200, JSON.generate(tool_call_payload(queued[:tool_calls]))) if queued[:tool_calls]

      rendered(200, JSON.generate(completion_payload(queued[:content])))
    end

    def streaming?(body)
      JSON.parse(body)["stream"] == true
    rescue JSON::ParserError
      false
    end

    def streamed(queued)
      calls = queued.to_h[:tool_calls]
      deltas = if calls then calls.each_with_index.flat_map { |call, at| fragments(call, at) }
      else queued.to_h[:content].to_s.scan(/\S+\s*|\s+/).map { |word| { "content" => word } }
      end
      deltas = [ { "content" => "" } ] if deltas.empty?

      events = deltas.map { |delta| "data: #{JSON.generate('choices' => [ { 'index' => 0, 'delta' => delta } ])}\n\n" }

      [
        [ "HTTP/1.1 200 OK", "Content-Type: text/event-stream", "Connection: close", "", "" ].join("\r\n"),
        *events,
        "data: [DONE]\n\n"
      ]
    end

    def fragments(call, at)
      arguments = call.dig("function", "arguments").to_s
      half = arguments.length / 2

      [
        { "tool_calls" => [ { "index" => at, "id" => call["id"], "type" => "function",
                              "function" => { "name" => call.dig("function", "name"), "arguments" => arguments[0, half] } } ] },
        { "tool_calls" => [ { "index" => at, "function" => { "arguments" => arguments[half..] } } ] }
      ]
    end

    def completion_payload(content)
      { "choices" => [ { "message" => { "role" => "assistant", "content" => content } } ] }
    end

    def tool_call_payload(calls)
      { "choices" => [ { "message" => { "role" => "assistant", "content" => nil,
                                        "tool_calls" => calls } } ] }
    end

    def record_prompt(body)
      parsed = JSON.parse(body)
      user = Array(parsed["messages"]).reverse.find { |message| message["role"] == "user" }
      content = user.to_h["content"]

      @lock.synchronize do
        @prompts << spoken(content)
        @attachments << attached(content)
        @efforts << parsed["reasoning_effort"]
        @systems << Array(parsed["messages"]).find { |message| message["role"] == "system" }.to_h["content"]
      end
    rescue JSON::ParserError
      @lock.synchronize do
        @prompts << body.to_s
        @attachments << []
      end
    end

    def spoken(content)
      return content.to_s unless content.is_a?(Array)

      content.filter_map { |part| part["text"] }.join("\n")
    end

    def attached(content)
      return [] unless content.is_a?(Array)

      content.filter_map { |part| part.dig("image_url", "url") }
    end

    def rendered(status, body)
      [
        "HTTP/1.1 #{status} #{reason(status)}",
        "Content-Type: application/json",
        "Content-Length: #{body.to_s.bytesize}",
        "Connection: close",
        "",
        body.to_s
      ].join("\r\n")
    end

    def reason(status)
      { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found",
        429 => "Too Many Requests", 500 => "Internal Server Error", 503 => "Service Unavailable" }
        .fetch(status, "Unknown")
    end
end
