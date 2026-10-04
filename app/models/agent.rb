class Agent
  class Refused < StandardError; end

  TURNS = 6
  FLAILING = 3
  READ_TOOLS = %w[search feed connect resource].freeze

  SYSTEM = <<~TEXT.freeze
    You are the xixo catalog agent. Use the tools to find what the request asks for.
    Call a tool rather than answering from memory. When you have enough, answer in one
    or two sentences and stop.
  TEXT

  WROTE_A_CALL = <<~TEXT.squish.freeze
    You wrote a tool call out as text instead of making it, so nothing ran. Make the call with the
    tool itself, then answer from what it returns.
  TEXT

  CLOSING_TURN = <<~TEXT.freeze
    You are almost out of time. Answer now from what you have already read, or call more_time if the
    request needs longer.
  TEXT

  LAST_TURN = <<~TEXT.freeze
    You have no turns left and no tools. Answer the request from what you have already
    read, in one or two sentences. If you never found it, say so plainly.
  TEXT

  Answer = Data.define(:said, :reason, :turns, :calls) do
    def answered? = reason == :answered

    def read
      calls.select { |call| call.ok && call.name == "feed" }
           .filter_map { |call| call.arguments[:id] || call.arguments["id"] }
           .uniq
    end
  end

  attr_reader :turns_taken, :calls

  def initialize(grant:, inference: nil, role: Resource::OpenaiCompatible::AGENT_ROLE, tools: nil, locals: [],
                 analysis: nil, turns: TURNS, halted: nil, unfinished: nil, system: SYSTEM, label: "agent",
                 reserve: 0, routine: false)
    @grant = grant
    @role = role
    @inference = inference || Resource.for_role(role)
    @offered = tools || grant.tools.select { |tool| READ_TOOLS.include?(tool.tool_name) }
    @analysis = analysis
    @turns = turns.to_i.clamp(1, 32)
    @halted = halted
    @unfinished = unfinished
    @system = system
    @label = label
    @routine = routine
    @pressed = Set.new
    @turns_taken = 0
    @calls = []
    @flailed = 0
    @clock = Clock.new(analysis, reserve: reserve)
    @locals = [ @clock, *locals ]
  end

  def call(prompt)
    raise Refused, "no inference resource serves the #{@role} role" if @inference.nil?

    transcript = Transcript.new(system: [ @system, Today.said, @clock.told ].compact.join("\n"), prompt: prompt)

    @turns.times do |index|
      return finished(:halted) if @halted&.call || @clock.spent?

      @turns_taken = index + 1
      last = @turns_taken == @turns
      closing = !last && @clock.closing?
      message = spoke(transcript, last: last, closing: closing)
      requested = Array(message["tool_calls"])

      if requested.blank? && !last && !closing && (pushed = pressed(message))
        transcript.said(message)
        transcript.closing(pushed)
        @analysis&.log_info(@label, "turn #{@turns_taken}", "pressed", pushed.truncate(200))
        next
      end

      return finished(:answered, message["content"]) if requested.blank? || last

      transcript.said(message)
      requested.zip(ran(requested)).each { |raw, result| answer(transcript, raw, result) }

      return finished(:flailed) if @flailed >= FLAILING
    end

    finished(:ran_out)
  end

  def inference_key = @inference&.key
  def offered_names = @offered.map(&:tool_name) + @locals.flat_map { |local| local.declared.map { |held| held.dig(:function, :name) } }

  private

    def spoke(transcript, last:, closing:)
      transcript.closing(LAST_TURN) if last
      transcript.closing(CLOSING_TURN) if closing

      @inference.converse(
        messages: transcript.messages,
        tools: if last then [] elsif closing then @clock.declared else declared end,
        role: @role,
        analysis: @analysis,
        turn: @turns_taken,
        effort: (@inference.routine_effort if @routine && @inference.respond_to?(:routine_effort))
      )
    end

    def declared
      told = @offered.map do |tool|
        {
          type: "function",
          function: {
            name: tool.tool_name,
            description: tool.description.to_s.strip,
            parameters: tool.input_schema.to_h
          }
        }
      end

      @locals.flat_map(&:declared) + told
    end

    def pressed(message)
      wanted = [ (WROTE_A_CALL if wrote_a_call?(message["content"])), @unfinished&.call(@calls).presence ]
      pushed = wanted.compact.find { |held| !@pressed.include?(held) }
      return nil if pushed.nil?

      @pressed << pushed
      pushed
    end

    def wrote_a_call?(content)
      held = Resource::OpenaiCompatible.extract_json(content.to_s.gsub(%r{<think>.*?</think>}m, ""))
      return false unless held.is_a?(Hash)

      named = (held["name"] || held.dig("function", "name")).to_s
      return true if offered_names.include?(named)

      held.key?("do") && (held.key?("key") || held.key?("id"))
    end

    def ran(requested)
      held = {}

      @locals.each do |local|
        mine = requested.select { |raw| local.handles?(raw) }
        next if mine.empty?

        mine.zip(local.call_all(mine)).each { |raw, result| held[raw.object_id] = result }
      end

      requested.map { |raw| held[raw.object_id] || dispatch.call(raw) }
    end

    def answer(transcript, raw, result)
      @calls << result
      @flailed = result.ok ? 0 : @flailed + 1

      note(result)
      transcript.answered(raw, result.content)
    end

    def dispatch
      @dispatch ||= Dispatch.new(offered: @offered, context: context)
    end

    def note(result)
      return if @analysis.nil?

      asked = result.arguments.to_h.to_json.truncate(200)

      if result.ok
        @analysis.log_done(@label, "turn #{@turns_taken}", result.name, asked)
      else
        @analysis.log_fail(@label, "turn #{@turns_taken}", result.name, asked, result.error)
      end
    end

    def finished(reason, said = nil)
      Answer.new(said: said.to_s.presence, reason: reason, turns: @turns_taken, calls: @calls)
    end

    def context
      { tenant_id: @grant.tenant.id, scopes: @grant.scopes }
    end
end
