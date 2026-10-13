class PlanMoveJob < ApplicationJob
  include JobIteration::Iteration
  include Gated

  queue_as :move

  gated_as "move"

  on_complete :start_moving

  rescue_from(StandardError) do |error|
    run&.finished!(error: "#{error.class}: #{error.message}")
    raise error
  end

  rescue_from(Resource::Unusable) do |error|
    run&.finished!(error: error.message)
  end

  def build_enumerator(_tenant_id, run_id, cursor:)
    run = Run.find(run_id)
    run.running!
    plan = run.selector

    return feeds(plan, cursor) if plan["feeds"]

    pages(plan, cursor)
  end

  def each_iteration(page, _tenant_id, _run_id)
    stop! if run.halted?

    page.each { |source, entries, feed| Move.planned!(run, source, entries, destination: destination, target: target_for, feed: feed) }
    run.announce!
  end

  def run
    @run ||= Run.find_by(id: arguments[1])
  end

  private

    def destination
      @destination ||= Resource::Filesystem.find(run.selector["destination_id"])
    end

    def target_for
      @target_for ||= ->(path) { [ destination.inner(run.selector["into"]), moved_as(path) ].compact_blank.join("/") }
    end

    def moved_as(path)
      return File.basename(path) if run.selector["feeds"]

      root = run.selector["root"].to_s
      return path if root.empty?

      [ File.basename(root), path.delete_prefix(root).delete_prefix("/") ].compact_blank.join("/")
    end

    def pages(plan, cursor)
      source = Resource::Filesystem.find(plan["source_id"])
      root = plan["root"].to_s

      listed = Enumerator.new do |yielder|
        source.each_page(cursor: cursor, prefix: root.presence) do |entries, after|
          inside = entries.select { |entry| root.empty? || entry.path == root || entry.path.start_with?("#{root}/") }
          yielder.yield([ [ source, inside, nil ] ], after)
        end
      end

      enumerator_builder.wrap(enumerator_builder, listed)
    end

    def feeds(plan, cursor)
      chosen = Feed.referenced.readable_to(plan["reader"]).matching(plan["feeds"].merge("reader" => plan["reader"]))

      batches = enumerator_builder.active_record_on_batches(chosen, cursor: cursor, batch_size: 100)
      found = Enumerator.new do |yielder|
        batches.each { |batch, at| yielder.yield(batch.flat_map { |feed| sources_of(feed) }, at) }
      end

      enumerator_builder.wrap(enumerator_builder, found)
    end

    def sources_of(feed)
      feed.references.originals.where(gone_at: nil).where.not(resource_id: destination.id).filter_map do |reference|
        source = reference.resource
        next unless source.is_a?(Resource::Filesystem) && source.machine.present?

        located = reference.locator.to_h
        entry = Resource::Filesystem::Entry.new(
          path: reference.locator_key, size: located["size"].to_i,
          modified_at: (Time.iso8601(located["modified_at"].to_s) rescue nil)
        )
        [ source, [ entry ], feed ]
      end
    end

    def start_moving
      return if stopped? || run.nil? || !run.open?

      if Move.where(run_id: run.id).none?
        run.line("[-]", "nothing here to move")
        return run.finished!
      end

      Move::AT_ONCE.times { |shard| MoveFilesJob.perform_later(run.tenant_id, run.id, shard, Move::AT_ONCE) }
    end
end
