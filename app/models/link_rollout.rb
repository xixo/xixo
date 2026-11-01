class LinkRollout < ApplicationRecord
  include TenantScoped

  PHASES = %w[waiting_for_server first everyone done held paused].freeze
  PLATFORMS = %w[linux darwin].freeze
  SERVER_HEALTHY_FOR = 15.minutes
  FIRST_HEALTHY_FOR = 30.minutes
  FIRST_WITHIN = 2.hours
  ACTIONS = %w[pause resume].freeze

  class Refused < StandardError; end

  validates :release, presence: true
  validates :phase, inclusion: { in: PHASES }

  class << self
    def shipped
      path = Resource::Machine::Downloads.release_file
      return nil if path.nil?

      described = JSON.parse(File.read(path, 1.megabyte))
      return nil unless described.is_a?(Hash)

      {
        "release" => Resource::Machine::Downloads.digest(path),
        "version" => Resource::Machine::Downloads.version || described["version"].to_s.presence,
        "serial" => (described["serial"] if described["serial"].is_a?(Integer)),
        "protocol" => (described["protocol"] if described["protocol"].is_a?(Integer))
      }
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def current
      held = shipped
      return nil if held.nil?

      find_by(release: held["release"])
    end

    def current!
      held = shipped
      return nil if held.nil?

      find_or_create_by!(release: held["release"]) do |rollout|
        rollout.version = held["version"]
        rollout.serial = held["serial"]
        rollout.protocol = held["protocol"]
        rollout.started_at = rollout.phase_at = Time.current
      end
    end

    def allows?(machine)
      rollout = current!
      rollout.nil? || rollout.includes?(machine)
    end

    def tend!
      current!&.advance!
    end

    def request!(action)
      raise Refused, "#{action.inspect} is not something a rollout does" unless ACTIONS.include?(action)

      rollout = current! || raise(Refused, "this xixo ships no release, so there is nothing to roll out")
      action == "pause" ? rollout.pause! : rollout.resume!
      rollout
    end
  end

  def includes?(machine)
    case phase
    when "everyone", "done" then true
    when "first" then first_ids.include?(machine.id)
    else false
    end
  end

  def first_ids
    first_machines.to_h.values.filter_map { |held| held["id"] }
  end

  def advance!
    case phase
    when "waiting_for_server" then start_first! if server_settled?
    when "first" then watch_first!
    when "everyone" then finish! if everyone_current?
    end
  end

  def first!(machine)
    raise Refused, "#{machine.key} cannot go first: #{machine.update_state}" unless machine.wants_update?
    raise Refused, "the rollout is past its first machines" unless %w[waiting_for_server first paused held].include?(phase)

    os = machine.machine["os"].to_s
    raise Refused, "#{machine.key} runs #{os.presence || 'an unknown system'}, which the rollout does not stage" unless PLATFORMS.include?(os)

    update!(phase: "first", phase_at: Time.current, held_reason: nil,
            first_machines: first_machines.to_h.merge(os => { "id" => machine.id, "picked" => true }))
    machine.offer_update!
  end

  def pause!
    return if phase == "paused"

    update!(phase: "paused", phase_at: Time.current, held_reason: nil)
  end

  def resume!
    return unless %w[paused held].include?(phase)

    update!(phase: first_machines.to_h.empty? ? "waiting_for_server" : "first", phase_at: Time.current, held_reason: nil,
            first_machines: first_machines.to_h.transform_values { |held| held.except("arrived_at") })
  end

  def hold!(reason)
    update!(phase: "held", phase_at: Time.current, held_reason: reason.to_s.first(500))
    Rails.logger.warn("link rollout #{version}: held: #{held_reason}")
  end

  def first_machine_entries
    first_machines.to_h.map do |os, held|
      { "os" => os, "id" => held["id"], "arrived_at" => held["arrived_at"], "picked" => held["picked"] == true }
    end
  end

  private

    def server_settled?
      if ServerUpdates.rolled_back_since?(started_at)
        hold!("the server rolled back")
        return false
      end

      Time.current - started_at >= SERVER_HEALTHY_FOR && ServerUpdates.healthy?
    end

    def start_first!
      picked = candidates.group_by { |machine| machine.machine["os"] }.slice(*PLATFORMS).transform_values do |machines|
        { "id" => best(machines).id }
      end
      picked = first_machines.to_h.merge(picked.reject { |os, _| first_machines.to_h.key?(os) })
      return everyone! if picked.empty?

      update!(phase: "first", phase_at: Time.current, first_machines: picked)
      offer_first!
    end

    def watch_first!
      changed = first_machines.to_h.deep_dup

      changed.each do |os, held|
        machine = Resource::Machine.active.find_by(id: held["id"])
        next changed.delete(os) if machine.nil?

        rollback = machine.rollback_from(self)
        return hold!("#{machine.name} went back to #{machine.machine['version']}: #{rollback['error']}") if rollback

        if machine.on?(self) && machine.connected?
          held["arrived_at"] ||= Time.current.utc.iso8601
        elsif held["arrived_at"]
          held.delete("arrived_at")
        elsif Time.current - phase_at >= FIRST_WITHIN && held["picked"] != true
          repick(os, held)
        end
      end

      update!(first_machines: changed) if changed != first_machines
      return everyone! if changed.empty? || changed.values.all? { |held| settled?(held) }

      offer_first!
    end

    def repick(os, held)
      tried = Array(held["tried"]) + [ held["id"] ]
      other = candidates.select { |machine| machine.machine["os"] == os && !tried.include?(machine.id) }
      held["id"] = other.empty? ? nil : best(other).id
      held["tried"] = tried
    end

    def settled?(held)
      held["id"].nil? || (held["arrived_at"] && Time.iso8601(held["arrived_at"]) <= FIRST_HEALTHY_FOR.ago)
    rescue ArgumentError
      false
    end

    def offer_first!
      Resource::Machine.active.where(id: first_ids).each(&:offer_update!)
    end

    def everyone!
      update!(phase: "everyone", phase_at: Time.current)
      candidates.each(&:offer_update!)
    end

    def finish!
      update!(phase: "done", phase_at: Time.current)
    end

    def everyone_current?
      candidates.empty?
    end

    def candidates
      Resource::Machine.active.select { |machine| machine.connected? && machine.wants_update? }
    end

    def best(machines)
      machines.min_by { |machine| [ -machine.updates_done, machine.id ] }
    end
end
