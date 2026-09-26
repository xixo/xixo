class AnalyzeFeedJob < ApplicationJob
  queue_as :analysis

  limits_concurrency to: ENV.fetch("ANALYSIS_PER_TENANT", 2).to_i,
                     key: ->(tenant_id, *) { "analysis/#{tenant_id}" },
                     duration: Feed::MAX_TIMEOUT

  rescue_from(StandardError) do |error|
    fail_analysis(error)
    raise error
  end

  discard_on(Analyzer::Failed, Placement::Nowhere) { |job, error| job.fail_analysis(error) }
  retry_on Resource::Failed, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.fail_analysis(error)
  end

  def perform(_tenant_id, feed_id, _analysis_id = nil)
    analysis&.running!

    feed = Feed.includes(references: :resource).find_by(id: feed_id)

    return finish if feed.nil?
    return gate_out if analysis&.halted?
    return answer(feed) if analysis&.cause == "ask"

    placement = Placement.new(feed, analysis: analysis)
    placement.returned!

    unless feed.address?
      ActiveRecord::Base.transaction(requires_new: true) do
        Analyzer.for(feed, analysis: analysis).run
      end
    end

    filed(feed)
    considered(feed)
    placement.settled!

    finish

    wake_parent(feed)
  end

  def fail_analysis(error)
    return if analysis.nil?
    return unless analysis.reload.open?

    analysis.finished!(error: "#{error.class}: #{error.message}")
  end

  FILE_PROMPT = <<~TEXT.freeze
    A new thing has just been catalogued. Read it, then connect it to whatever else in the
    catalog belongs beside it: file it under tags with connect, naming each tag with `tag`,
    and connect it by id to any feed it is about. Make the connections with the tools rather
    than describing them, then say in one sentence what you filed it as.
  TEXT

  private

    def answer(feed)
      asking = Asking.new(feed, analysis: analysis)
      grant = (analysis || feed).grant(scopes: Feed::ASKING_SCOPES)
      scouting = Scouting.new(grant: grant, analysis: analysis, briefing: ->(task) { asking.briefing(task) },
                              unfinished: ->(calls) { asking.unfinished(calls) })
      lead = Agent.new(grant: grant, analysis: analysis, tools: [], locals: [ scouting ], turns: Asking::TURNS,
                       halted: -> { analysis.halted? }, unfinished: ->(calls) { asking.led(calls) },
                       system: Asking::LEAD_SYSTEM, label: "lead")

      asking.title!
      Current.grant = grant
      Current.acting_for = feed.id
      Current.analysis = analysis
      Current.confined_to = Concurrent::Set.new
      led = lead.call(asking.prompt)
      answered = led.with(calls: scouting.calls)
      analysis.log_info("lead", led.reason.to_s, led.said)
      noted(answered)
      spoken(answered.said)
      drew(feed, asking.connections(answered))
      verified(asking, answered)
      asking.title!(later: true)
      Analyzer::Conversation.new(feed, analysis: analysis).roll_up!

      finish
    rescue Agent::Refused, Resource::Unusable => e
      analysis.finished!(error: e.message)
    ensure
      Current.grant = nil
      Current.acting_for = nil
      Current.analysis = nil
      Current.confined_to = nil
    end

    def drew(feed, held)
      found = held.to_a
      found.each { |other| feed.connect!(other) }

      now = Time.current.iso8601(3)
      analysis.write_step!("drew_on", { "started_at" => now, "finished_at" => now, "result" => found.map(&:id) })
    end

    def verified(asking, answered)
      started = Time.current.iso8601(3)
      verdict = Verifier.new(analysis: analysis).call(question: asking.judged_question, answer: answered.said,
                                                      calls: answered.calls)
      return if verdict.nil?

      analysis.log_info("verify", "answered #{verdict.score}", "worth keeping #{verdict.useful}", "#{verdict.runs} judges")
      analysis.write_step!("verified", { "started_at" => started, "finished_at" => Time.current.iso8601(3),
                                         "result" => verdict.to_h })
    end

    def spoken(said)
      return if said.blank?

      now = Time.current.iso8601(3)
      analysis.write_step!("text", { "started_at" => now, "finished_at" => now, "result" => said })
    end

    def filed(feed)
      mime = feed.mime
      return if mime.blank?

      feed.connect!(Feed.mime!(mime))
    end

    def considered(feed)
      grant = (analysis || feed).grant
      agent = Agent.new(grant: grant, analysis: analysis, turns: turns_for(feed),
                        halted: -> { analysis&.halted? })

      return if agent.inference_key.nil?

      Current.grant = grant
      Current.acting_for = feed.id
      Current.analysis = analysis
      answered = agent.call(asked(feed))
      analysis&.log_info("agent", answered.reason.to_s, answered.said)
      noted(answered)
    rescue Agent::Refused, Resource::Unusable => e
      analysis&.log_skip("agent", e.message)
    ensure
      Current.grant = nil
      Current.acting_for = nil
      Current.analysis = nil
    end

    def noted(answered)
      return if analysis.nil?

      now = Time.current.iso8601(3)
      analysis.write_step!("answer", {
        "started_at" => now, "finished_at" => now,
        "result" => { "said" => answered.said.to_s.truncate(4_000), "reason" => answered.reason.to_s }
      })
    end

    def asked(feed)
      return [ feed.schedule.prompt, searchable(feed) ].compact.join("\n\n") if feed.address? && feed.schedule

      [ FILE_PROMPT, "It is feed #{feed.id}, called #{feed.title || feed.key}.", unplaced(feed) ]
        .compact.join("\n\n")
    end

    def searchable(feed)
      reach = Reach.new((analysis || feed).grant).told
      return nil if reach.nil?

      <<~TEXT
        Beyond the catalog you can look at the web. #{reach} Keep anything worth keeping: make a
        note with feed, do=create, type uris:note and a title naming it, write what it is and its
        address with feed, do=note, and connect the note to feed #{feed.id} with connect.
      TEXT
    end

    def unplaced(feed)
      return nil unless feed.reload.staged?

      offered = Placement.candidates(feed).map do |resource|
        "- `#{resource.key}`, #{resource.name}#{', the default' if resource.default_storage?}"
      end

      <<~TEXT
        It has not been stored anywhere yet. Choose where it belongs with feed, do=place, passing
        the key in backticks as resource and saying in one sentence why. These are the places that
        accept it:

        #{offered.join("\n")}

        If none is clearly right, leave it; it goes to default storage.
      TEXT
    end

    def turns_for(feed)
      feed.schedule&.turns_allowed || Agent::TURNS
    end

    def finish
      analysis&.finished!
    end

    def gate_out
      nil
    end

    def analysis
      return @analysis if defined?(@analysis)

      @analysis = Analysis.find_by(id: arguments[2]) || opened
    end

    def opened
      feed = Feed.find_by(id: arguments[1])

      feed && Analysis.open!(feed: feed, cause: "manual")
    end

    def wake_parent(feed)
      parent = feed.parent
      return if parent.nil? || feed.analyzed_at.nil?
      return unless parent.children_ready?

      parent.analyze!(cause: "sync")
    end
end
