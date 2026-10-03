class Scouting
  NAME = "scout".freeze
  ROLE = Resource::OpenaiCompatible::SCOUT_ROLE
  TURNS = 8
  REPORT = 1_500
  MOST = 6
  RESERVE = 90.seconds

  SYSTEM = <<~TEXT.freeze
    You are a scout for the uris catalog agent. Do the one task you are given with the tools, then
    report in a few sentences what the tools returned that bears on it: every feed you drew on or
    made, by id like [feed 12], and every page you read, by its address. Report only what the tools
    returned. If you found nothing, say so plainly.
  TEXT

  DECLARED = {
    type: "function",
    function: {
      name: NAME,
      description: "Send a scout to do one task with the catalog and web tools, in a fresh context, and " \
                   "get back a short report of what it found and kept. Send several in one turn when the " \
                   "work has several parts; they run side by side.",
      parameters: {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "One concrete thing to find or keep, written so someone with no other context could do it."
          }
        },
        required: %w[task]
      }
    }
  }.freeze

  attr_reader :calls

  def self.at_once
    Rails.configuration.uris.scouts_at_once.to_i.clamp(1, MOST)
  end

  def initialize(grant:, analysis: nil, briefing: ->(task) { task }, unfinished: nil)
    @grant = grant
    @analysis = analysis
    @briefing = briefing
    @unfinished = unfinished
    @calls = []
    @sent = 0
    @lock = Mutex.new
  end

  def declared = [ DECLARED ]

  def handles?(raw)
    raw.to_h.dig("function", "name") == NAME
  end

  def call_all(raws)
    numbered = raws.map { |raw| [ task(raw), @lock.synchronize { @sent += 1 } ] }
    return numbered.map { |task, number| scouted(task, number) } if Scouting.at_once == 1 || numbered.size == 1

    numbered.each_slice(Scouting.at_once).flat_map do |slice|
      threads = slice.map { |task, number| alongside { scouted(task, number) } }

      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.map(&:value) }
    end
  end

  private

    def scouted(task, number)
      return refused(task, "a scout needs a task") if task.blank?
      return refused(task, "no more than #{MOST * 4} scouts go out for one run") if number > MOST * 4

      inference, role = scout_inference
      held = @analysis && Analysis.find(@analysis.id)
      agent = Agent.new(grant: @grant, inference: inference, role: role, analysis: held, turns: TURNS,
                        halted: -> { held&.halted? }, unfinished: @unfinished, system: SYSTEM,
                        label: "scout #{number}", reserve: RESERVE)
      answered = agent.call(@briefing.call(task))

      @lock.synchronize { @calls.concat(answered.calls) }
      reported(task, answered)
    rescue Agent::Refused, Resource::Unusable, Resource::Failed => e
      refused(task, e.message)
    end

    def reported(task, answered)
      said = answered.said.to_s.squish.presence || "The scout came back with nothing to say."

      Agent::Dispatch::Result.new(
        name: NAME, arguments: { "task" => task }, ok: true, error: nil,
        content: { report: said.truncate(REPORT), turns: answered.turns, stopped: answered.reason.to_s }.to_json
      )
    end

    def scout_inference
      declared = Resource.for_declared_role(ROLE)
      return [ declared, ROLE ] if declared

      [ Resource.for_role(Resource::OpenaiCompatible::AGENT_ROLE), Resource::OpenaiCompatible::AGENT_ROLE ]
    end

    def alongside(&work)
      context = Current.attributes.slice(:tenant, :grant, :acting_for, :confined_to, :audit, :analysis)

      Thread.new do
        Rails.application.executor.wrap do
          Tenant.switch(context[:tenant]) { Current.set(**context.except(:tenant)) { work.call } }
        end
      end
    end

    def task(raw)
      JSON.parse(raw.to_h.dig("function", "arguments").to_s).then { |held| held.is_a?(Hash) ? held["task"].to_s.strip : "" }
    rescue JSON::ParserError
      ""
    end

    def refused(task, complaint)
      Agent::Dispatch::Result.new(name: NAME, arguments: { "task" => task }, ok: false, error: complaint,
                                  content: { error: complaint }.to_json)
    end
end
