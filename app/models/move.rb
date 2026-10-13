class Move < ApplicationRecord
  include TenantScoped

  STATUSES = %w[waiting done failed].freeze
  AT_ONCE = 3
  LASTS = 3.days

  Progress = Data.define(:files, :files_done, :files_failed, :bytes, :bytes_done)

  belongs_to :run
  belongs_to :source, class_name: "Resource"
  belongs_to :destination, class_name: "Resource"
  belongs_to :feed, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :waiting, -> { where(status: "waiting") }
  scope :failed, -> { where(status: "failed") }

  def self.start!(grant:, destination:, into: nil, source: nil, path: nil, feeds: nil)
    movable!(destination, grant)
    into = folder_inside!(into, "into")
    selector = { "destination_id" => destination.id, "into" => into }

    if source
      raise ArgumentError, "a move takes a folder or a selection of files, not both" if feeds.present?
      raise ArgumentError, "the files already live in #{destination.key}" if source.id == destination.id

      movable!(source, grant)
      selector = selector.merge("source_id" => source.id, "root" => source.inner(folder_inside!(path, "path")))
    else
      raise ArgumentError, "a move takes a folder or a selection of files" if feeds.blank?

      reader = grant&.speaks_for
      sources_of(feeds, reader, destination).each { |held| movable!(held, grant) }
      selector = selector.merge("feeds" => feeds.to_h, "reader" => reader)
    end

    run = Run.start!(kind: "move", resource: destination, selector: selector, deadline: LASTS.from_now)
    PlanMoveJob.perform_later(run.tenant_id, run.id)
    run
  end

  def self.movable!(resource, grant)
    unless resource.is_a?(Resource::Filesystem) && resource.machine
      raise Resource::Refused, "#{resource.key} is not a folder on a machine running xixo link, so files do not move in or out of it"
    end

    unless resource.machine.operated_by?(grant)
      raise Resource::Refused, "only an operator of #{resource.machine.key} moves files in or out of #{resource.key}. " \
                               "An administrator lists who operates it on the Resources page"
    end

    resource.movable!
  end

  def self.sources_of(feeds, reader, destination)
    chosen = Feed.referenced.readable_to(reader).matching(feeds.to_h.merge("reader" => reader))
    held = Reference.originals.where(gone_at: nil, feed_id: chosen.select(:id)).where.not(resource_id: destination.id)
    found = Resource::Filesystem.where(id: held.select(:resource_id)).to_a
    raise ArgumentError, "none of those files lives in a folder on a machine running xixo link" if found.empty?

    found
  end

  def self.folder_inside!(path, named)
    held = path.to_s.delete_prefix("/").chomp("/")
    return "" if held.empty?
    return held if Resource::Filesystem.inside?(held)

    raise ArgumentError, "#{named} names a folder inside the resource, such as Photos/2019"
  end

  def self.progress(run_id)
    counted = where(run_id: run_id).group(:status).pluck(:status, Arel.sql("count(*)"), Arel.sql("coalesce(sum(size), 0)"))
    held = counted.to_h { |status, files, bytes| [ status, [ files, bytes ] ] }
    done = held.fetch("done", [ 0, 0 ])

    Progress.new(
      files: counted.sum { |row| row[1] }, files_done: done[0], files_failed: held.fetch("failed", [ 0, 0 ])[0],
      bytes: counted.sum { |row| row[2] }, bytes_done: done[1]
    )
  end

  def self.planned!(run, source, entries, destination:, target:, feed: nil)
    now = Time.current
    rows = entries.map do |entry|
      {
        tenant_id: run.tenant_id, run_id: run.id, source_id: source.id, destination_id: destination.id,
        feed_id: feed&.id, path: entry.path, target: target.call(entry.path), size: entry.size,
        modified_at: entry.modified_at, status: "waiting", created_at: now, updated_at: now
      }
    end

    insert_all(rows, unique_by: %i[run_id source_id path]) if rows.any?
  end

  def carry!
    return self unless status == "waiting"

    landed = destination.entry_at(target)
    landed ? kept_if_same!(landed) : Resource::Machine::Relay.new(
      from: source.machine, folder: source.folder, path: path, size: size,
      to: destination.machine, into: destination.folder, target: target, modified_at: modified_at
    ).copy!

    copied = destination.hashed(target, size: size)
    return mismatched!(copied, landed) unless copied["size"] == size

    left!(copied, landed)
  rescue Resource::Unusable
    raise
  rescue Resource::Failed, Resource::Refused => e
    raise Resource::Offline, e.message unless source.machine.connected? && destination.machine.connected?

    failed!(e.message)
  end

  private

    def kept_if_same!(landed)
      return if landed.size == size && destination.hashed(target, size: size)["sha256"] == source.hashed(path, size: size)["sha256"]

      raise Resource::Failed, "#{destination.key} already holds another file at #{target}, so #{path} stays where it is"
    end

    def mismatched!(copied, landed)
      destination.removed!(target, sha256: copied["sha256"], size: copied["size"]) unless landed

      failed!("#{destination.key} holds #{copied['size']} bytes of #{target}, not #{size}, so #{path} stays where it is")
    end

    def left!(copied, landed)
      begin
        source.removed!(path, sha256: copied["sha256"], size: copied["size"], prune: true)
      rescue Resource::Machine::Refusal => e
        destination.removed!(target, sha256: copied["sha256"], size: copied["size"]) unless landed
        return failed!("#{path} stays on #{source.key}, since #{e.message.sub(/\A[^:]+: /, '')}")
      end

      catalogued!(copied["sha256"])
      update!(status: "done", sha256: copied["sha256"], error: nil)
      self
    end

    def catalogued!(sha256)
      moving = Reference.originals.find_by(resource_id: source_id, locator_key: path)
      return if moving.nil?

      located = destination.locator_for(Resource::Filesystem::Entry.new(path: target, size: size,
                                                                         modified_at: modified_at || Time.current))

      Reference.transaction do
        landed = Reference.find_by(resource_id: destination_id, locator_key: target)
        if landed && landed.id != moving.id
          left_behind = landed.feed
          landed.destroy!
          left_behind.reload.destroy_if_empty! unless left_behind.id == moving.feed_id
        end

        moving.update!(resource_id: destination_id, locator_key: target, locator: located,
                       version: destination.version_for(located), digest: sha256, gone_at: nil, seen_at: Time.current)
      end

      update_columns(feed_id: moving.feed_id)
    end

    def failed!(error)
      update!(status: "failed", error: Redaction.scrub(error.to_s).truncate(500))
      self
    end
end
