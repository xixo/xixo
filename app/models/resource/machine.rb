class Resource
  class Machine < Resource
    class Refusal < Resource::Failed; end

    MOST_CHUNKED = 256.kilobytes
    QUIET_AFTER = 3.minutes
    ANSWERED_WITHIN = 30.seconds
    READ_STALLS_AFTER = 60.seconds
    POLLED_EVERY = 0.05
    MOST_FOLDERS = 64
    MOST_SERVICES = 16
    MOST_DISKS = 32
    MOST_TEXT = 255
    MOST_WARNINGS = 16
    MOST_WARNING = 500
    MOST_PATH = 4096
    MOST_RESULT = 4.megabytes
    SERVICE_KINDS = %w[ollama lmstudio].freeze
    PUT_AWAY_TRIES = 3
    EXTRACTORS = %w[pdf image media doc epub xlsx calendar pkpass email contact data text fallback].freeze
    READ_AS = {
      "pdf" => "PDFs", "image" => "photos", "media" => "audio and video", "doc" => "office documents",
      "epub" => "books", "xlsx" => "spreadsheets", "calendar" => "calendars", "pkpass" => "passes", "email" => "email",
      "contact" => "contacts", "data" => "data files", "text" => "text", "fallback" => "files of unknown kinds"
    }.freeze
    LOCAL = "local".freeze
    MINTED = "minted_at".freeze
    CLIENT_ID = /\A[A-Za-z0-9._:-]{1,200}\z/
    ACCESS = %w[search files writing].freeze
    DEFAULT_ACCESS = "search".freeze
    ASKED_TOOLS = {
      "search" => %w[browse search read],
      "files" => %w[browse search read extract],
      "writing" => %w[browse search read extract write]
    }.freeze

    include Tools
    include Updates

    serves :transport

    before_validation(on: :create) { operated_by!(Current.grant) }

    validate :shared_by_everyone
    validates :access, inclusion: { in: ACCESS }

    after_commit :hang_up, on: %i[update destroy], if: -> { put_away_now? || client_replaced? }

    class << self
      def attaching
        {
          label: "A machine running xixo link",
          blurb: "A machine links itself up with one command from the Resources page, and an administrator " \
                 "approves it.",
          names: "A name for the machine",
          fields: [
            field("operators", "Who operates it", kind: "lines",
                  help: "The masks subjects, one per line, whose clients may browse its folders, read its files' " \
                        "bytes, write into them, run its readers, and ask its model server. The administrator " \
                        "who approves the machine is listed on their own. Anyone else reaches only what xixo " \
                        "drew out of its files.")
          ]
        }
      end

      def approved!(request, client_id)
        create!(
          key: free_key(request.hostname), name: short(request.hostname).presence || request.hostname,
          details: {
            "client_id" => client_id, "access" => DEFAULT_ACCESS, "helps_others" => true,
            "operators" => [ request.decided_by ].compact,
            "approved" => { "by" => request.decided_by, "at" => request.decided_at&.utc&.iso8601 }.compact,
            "about" => request.details.to_h.slice("system", "model", "kind").compact
          }
        )
      end

      def unlinked_peers(grant)
        linked = active.to_a
        names = linked.flat_map { |machine| [ machine.machine["hostname"], machine.key ] }.compact_blank.map { |name| short(name) }
        addresses = linked.flat_map(&:answers_at)

        Tailnet.visible_to(grant).active.order(:key).flat_map do |tailnet|
          tailnet.discovered(services: true).filter_map do |node|
            next unless node["online"]
            next if names.include?(short(node["host_name"])) || (node["addresses"] & addresses).any?

            node.merge("via" => tailnet.key)
          end
        rescue Resource::Failed, Resource::Unusable
          []
        end
      end

      def short(name)
        name.to_s.downcase.split(".").first
      end

      def base_key(hostname)
        hostname.to_s.split(".").first.to_s.gsub(/[^a-z0-9-]+/, "-").delete_prefix("-").delete_suffix("-").presence || "machine"
      end

      def free_key(hostname)
        base = base_key(hostname)
        taken = where("resources.key = ? OR resources.key LIKE ?", base, "#{sanitize_sql_like(base)}-%").pluck(:key)

        ([ base ] + (2..).lazy.map { |n| "#{base}-#{n}" }.first(taken.size + 1)).find do |key|
          key != LOCAL && !taken.include?(key)
        end
      end

      def command_schema
        { health: {}, discover: {} }.merge(tools_schema)
      end

      def command_help
        tools_help
      end

      def routable?
        true
      end

      def enrolled(client_id)
        return nil if client_id.blank?

        active.find_by("resources.details ->> 'client_id' = ?", client_id.to_s)
      end

      def carried_for!(resource, grant)
        return if grant&.administers? || !resource.via.is_a?(Machine)

        raise Resource::Refused, "only an administrator reaches a folder through a machine running xixo link. " \
                                 "#{Grant::ADMINISTERING}"
      end

      def local
        active.find_by("resources.details ->> 'local' = 'true'")
      end

      def pool
        active.order(:id).select { |machine| machine.connected? && machine.reads_for_others? }
      end

      def holding(resources)
        machines = active.to_a
        by_id = machines.index_by(&:id)
        local = machines.find(&:local?)
        reached = machines.reject(&:local?).each_with_object({}) do |machine, held|
          machine.answers_at.each { |address| held[address] ||= machine }
        end

        resources.to_h do |resource|
          next [ resource.id, nil ] if resource.is_a?(Machine)

          [ resource.id, by_id[resource.via_id] || reached[resource.target_host] || local ]
        end
      end

      def local!
        find_by(key: LOCAL) || create!(key: LOCAL, name: "This server", details: { "local" => true })
      end

      def adopted_by!(grant)
        return unless grant&.administers? && grant.speaks_for.present?

        where(key: LOCAL).where("NOT (resources.details ? 'operators')").update_all(
          [ "details = details || jsonb_build_object('operators', jsonb_build_array(?::text))", grant.speaks_for ]
        )
      end

      def binaries
        Pathname.new(ENV.fetch("XIXO_LINK_DIR", "/opt/xixo-link"))
      end
    end

    def machine
      details.to_h["machine"].to_h
    end

    def client_id
      details.to_h["client_id"]
    end

    def answers_at
      [ target_host, *Array(machine["services"]).map { |service| service["address"] } ].compact_blank.uniq
    end

    def reached_at(service)
      return if service["address"].blank?

      OpenaiCompatible.address_on(service["address"], port: service["port"])
    end

    def offered_folders
      Array(machine["folders"])
    end

    def writable_folders
      writes? ? Array(machine["writable"]) & offered_folders : []
    end

    def heard_from?
      machine.key?("folders")
    end

    def extractors
      Array(machine["extractors"])
    end

    def warnings
      Array(machine["warnings"]).grep(String)
    end

    def extracts?(kind)
      extractors.include?(kind.to_s)
    end

    def local?
      details.to_h["local"] == true
    end

    def access
      held = details.to_h["access"]
      return held if held.present?

      local? ? "writing" : DEFAULT_ACCESS
    end

    def helps_others?
      details.to_h["helps_others"] != false
    end

    def policy
      tools = ASKED_TOOLS.fetch(access, ASKED_TOOLS[DEFAULT_ACCESS])
      tools += [ "models" ] if model_kinds.any?

      { "tools" => Tools::NAMES & tools, "lend" => access != "search", "extracts_for_others" => helps_others? }
    end

    def about
      details["about"].to_h
    end

    def lends?
      machine["lend"] == true && policy["lend"]
    end

    def writes?
      offers?("write")
    end

    def held_back
      ceiling = Array(machine["tools"])
      tools = policy["tools"] - ceiling
      tools += [ "lend" ] if policy["lend"] && machine["lend"] == false
      tools += [ "extracts_for_others" ] if policy["extracts_for_others"] && machine["extracts_for_others"] == false
      heard_from? ? tools : []
    end

    def set_access!(access: nil, helps_others: nil)
      held = details.to_h
      held = held.merge("access" => access) unless access.nil?
      held = held.merge("helps_others" => helps_others) unless helps_others.nil?
      update!(details: held)
      tell!
      announce!
    end

    def tell!
      LinkChannel.broadcast_to(self, { "settings" => policy })
    end

    def seen_at
      Time.iso8601(machine["seen_at"].to_s)
    rescue ArgumentError
      nil
    end

    def connected?
      machine["connected"] == true && seen_at.present? && seen_at > QUIET_AFTER.ago
    end

    def extracts_for_others
      machine["extracts_for_others"] == true && policy["extracts_for_others"]
    end

    def reads_for_others?
      extracts_for_others
    end

    def announce!
      XixoSchema.subscriptions.trigger(:machine_changed, { id: id.to_s }, Resource.find(id), scope: tenant_id)
      XixoSchema.subscriptions.trigger(:machine_changed, {}, Resource.find(id), scope: tenant_id)
    rescue StandardError => e
      Rails.logger.warn "machine #{id} could not announce: #{e.message}"
    end

    def check!
      reload unless new_record? || changed?
      return true if connected?
      raise Resource::Failed, "#{key}: xixo link beside the server has not enrolled yet" if client_id.blank? && local?
      raise Resource::Failed, "#{key}: the machine is not linked. Run the link-up command on it again" if client_id.blank?
      raise Resource::Failed, "#{key}: xixo link has never connected" if seen_at.nil?

      raise Resource::Failed, "#{key}: xixo link was last heard from #{seen_at.utc.iso8601}"
    end

    def carries?(resource)
      resource.is_a?(Filesystem) || resource.is_a?(OpenaiCompatible)
    end

    def reach!(_target)
      raise Resource::Refused, "#{key} reaches only the folders it shares"
    end

    def covers
      []
    end

    def offline_peer(_host)
      return nil if connected?

      { "host_name" => machine["hostname"].presence || key, "last_seen" => seen_at&.utc&.iso8601 }
    end

    def discovered(services: false)
      offered_folders.map do |path|
        {
          "host_name" => File.basename(path).downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-").presence,
          "dns_name" => machine["hostname"],
          "addresses" => [],
          "online" => connected?,
          "last_seen" => seen_at&.utc&.iso8601,
          "services" => [ { "name" => "folder", "port" => 0, "type" => Filesystem.sti_name, "address" => path } ]
        }
      end
    end

    def command_health
      ask("health")
    end

    def command_discover
      { "transport" => key, "nodes" => discovered }
    end

    def ask(verb, args = {}, within: ANSWERED_WITHIN)
      exchanged(verb, args, within: within, &:result)
    end

    def exchanged(verb, args = {}, within: ANSWERED_WITHIN)
      exchange = asked(verb, args)

      yield Answer.new(self, exchange, awaited(exchange, verb, within))
    ensure
      LinkExchange.apart { LinkExchange.where(id: exchange.id).delete_all } if exchange
    end

    def read(folder, path, within: ANSWERED_WITHIN)
      exchanged("read", { "folder" => folder, "path" => path }, within: within) do |answer|
        Reading.new(self, answer.exchange, size: answer.result.to_h["size"]).file
      end
    end

    def glimpse(folder, path, limit:, within: ANSWERED_WITHIN)
      exchanged("read", { "folder" => folder, "path" => path, "limit" => limit }, within: within) do |answer|
        held = answer.result.to_h
        file = Reading.new(self, answer.exchange, size: held["size"]).file

        begin
          [ file.read(limit).to_s, held["total"].is_a?(Integer) ? held["total"] : held["size"] ]
        ensure
          file.close!
        end
      end
    end

    def upload(io)
      raise Resource::Offline, "#{key}: xixo link is not connected" unless connected?

      LinkExchange.apart { staged(io) }
    end

    def forget(request)
      LinkExchange.apart { LinkExchange.where(resource_id: id, request: request.to_s).delete_all }
    end

    def waiting
      sleep POLLED_EVERY
    end

    def greeted!(said, session:)
      merge_machine!(Hello.from(said).merge("session" => session, "connected" => true, "seen_at" => now_stamp))
      update_columns(offline_host: nil, offline_last_seen_at: nil, checked_at: Time.current, check_error: nil)
      reload
      tell!
      offer_update!
      restate_folders!
      ResumeParkedJob.perform_later(id) if Analysis.parked.exists?
      announce!
    end

    def restate_folders!
      Filesystem.where(via_id: id).find_each do |folder|
        held = folder.served
        folder.update_columns(serving: held) unless folder.serving == held
      end
    end

    def changed!(said)
      said = said.to_h
      folder = Hello.folder(said["folder"])
      return if folder.nil? || !offered_folders.include?(folder)

      paths = Hello.listed(said["paths"]).first(Filesystem::MOST_CHANGED).select { |path| Filesystem.inside?(path) }.uniq
      Filesystem.active.where(via_id: id).where.not(sync_interval: nil)
                .where("resources.details ->> 'folder' = ?", folder).find_each do |held|
        held.changed_later!(paths, everything: said["overflow"] == true)
      end
    end

    def heard!(said)
      merge_machine!("health" => Health.from(said), "warnings" => Hello.warnings(said.to_h["warnings"]), "seen_at" => now_stamp)
      update_columns(checked_at: Time.current, check_error: nil) if check_error.present?
    end

    def parted!(session:)
      Resource.where(id: id)
              .where("resources.details -> 'machine' ->> 'session' = ?", session.to_s)
              .update_all([ <<~SQL.squish, now_stamp, machine["hostname"].presence || key, Time.current ])
                details = jsonb_set(details, '{machine}', (details -> 'machine') || jsonb_build_object('connected', false, 'seen_at', ?::text)),
                offline_host = ?, offline_last_seen_at = ?
              SQL
      announce!
    end

    def bound!(client_id, revoker: Enrollment.method(:revoke))
      return if self.client_id == client_id

      revoker.call(tenant, self.client_id) if self.client_id.present?
      self.details = details.to_h.merge("client_id" => client_id).except("machine", MINTED)
      self.check_error = nil
      self.checked_at = nil
      save!
      announce!
    end

    def unenroll!(revoker: Enrollment.method(:revoke))
      return if client_id.blank?

      revoker.call(tenant, client_id)
      self.details = unenrolled_details
      save!
    end

    def put_away(revoker: Enrollment.method(:revoke))
      self.archived_at = Time.current
      return false unless valid?

      restore_attributes([ :archived_at ])

      PUT_AWAY_TRIES.times do
        client = Machine.find(id).client_id
        revoker.call(tenant, client) if client.present?

        done = transaction do
          held = Machine.lock.find(id)
          next nil unless held.client_id == client

          held.archived_at = Time.current
          held.details = held.unenrolled_details if client.present?
          held.save
        end
        next if done.nil?

        reload
        return done
      end

      errors.add(:base, "#{key} enrolled again while it was being put away. Try again")
      false
    rescue Resource::Failed => e
      errors.add(:base, "#{e.message}, so #{key} stays attached and xixo link on it keeps signing in. Try again once masks answers")
      false
    end

    def forgotten!(client)
      transaction do
        held = Machine.lock.find(id)
        next unless held.client_id == client

        held.details = held.unenrolled_details
        held.save!
      end
      reload
    end

    def unenrolled_details
      details.to_h.except("client_id").merge("unenrolled" => { "client_id" => client_id, "at" => now_stamp })
    end

    private

      def shared_by_everyone
        errors.add(:owner_subject, "cannot be set on a machine, which an administrator attaches for everyone") if personal?
      end

      def put_away_now?
        destroyed? || (saved_change_to_archived_at? && archived_at.present?)
      end

      def client_replaced?
        before = details_before_last_save.to_h["client_id"]

        before.present? && before != client_id
      end

      def hang_up
        clients = [ details_before_last_save.to_h["client_id"] ]
        clients << client_id if put_away_now?

        clients.compact.uniq.each do |client|
          ActionCable.server.remote_connections.where(tenant: tenant, grant: nil, machine: self, client_id: client)
                     .disconnect(reconnect: false)
        end
      end

      def asked(verb, args)
        raise Resource::Offline, "#{key}: xixo link is not connected" unless connected?

        exchange = LinkExchange.apart do
          raise Resource::Failed, "#{key}: xixo link already has #{LinkExchange::MOST_OPEN} questions open" if LinkExchange.crowded?(self)

          LinkExchange.create!(resource_id: id, request: SecureRandom.uuid, verb: verb)
        end
        LinkChannel.broadcast_to(self, { "request" => exchange.request, "verb" => verb, "args" => args.presence || {} })
        exchange
      end

      def staged(io)
        raise Resource::Failed, "#{key}: xixo link already has #{LinkExchange::MOST_OPEN} questions open" if LinkExchange.crowded?(self)

        exchange = LinkExchange.create!(resource_id: id, request: SecureRandom.uuid, verb: LinkExchange::UPLOAD)
        size = 0

        (0..).each do |seq|
          part = io.read(MOST_CHUNKED)
          break if part.nil?

          size += part.bytesize
          raise Resource::Failed, "#{key}: an upload is larger than #{LinkExchange::MOST_RECEIVED} bytes" if size > LinkExchange::MOST_RECEIVED

          exchange.chunks.create!(seq: seq, bytes: part)
        end

        exchange.update_columns(received: size)
        { "upload" => exchange.request, "size" => size }
      rescue StandardError
        LinkExchange.where(id: exchange.id).delete_all if exchange
        raise
      end

      def awaited(exchange, verb, within)
        LinkExchange.apart { waited(exchange, verb, within) }
      end

      def waited(exchange, verb, within)
        deadline = within.from_now

        loop do
          held = LinkExchange.uncached { LinkExchange.find(exchange.id) }
          return held.result if held.answered?
          raise Refusal, "#{key}: xixo link said #{held.error}" if held.refused?

          if Time.current > deadline
            held.refuse!("no answer in #{within.inspect}")
            raise Resource::Failed, "#{key}: xixo link did not answer #{verb} in #{within.inspect}"
          end

          waiting
        end
      end

      def merge_machine!(held)
        Resource.where(id: id).update_all([ <<~SQL.squish, held.to_json ])
          details = jsonb_set(details, '{machine}', COALESCE(details -> 'machine', '{}'::jsonb) || ?::jsonb)
        SQL
      end

      def now_stamp
        Time.current.utc.iso8601
      end
  end
end
