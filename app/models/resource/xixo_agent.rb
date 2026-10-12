class Resource
  class XixoAgent < Resource
    MOST_CHUNKED = 256.kilobytes
    QUIET_AFTER = 3.minutes
    ANSWERED_WITHIN = 30.seconds
    READ_STALLS_AFTER = 60.seconds
    POLLED_EVERY = 0.05
    MOST_FOLDERS = 64
    MOST_SERVICES = 16
    MOST_DISKS = 32
    MOST_TEXT = 255
    MOST_PATH = 4096
    MOST_RESULT = 4.megabytes
    SERVICE_KINDS = %w[ollama lmstudio].freeze

    serves :transport

    validate :shared_by_everyone

    before_save :unenroll, if: :put_away?
    after_commit :install_later, on: %i[create update], if: :key_given?
    after_commit :hang_up, on: %i[update destroy], if: :put_away_now?

    class << self
      def attaching
        {
          label: "A machine with the xixo agent",
          blurb: "A Linux machine xixo connects to once over SSH, installs the agent on, and enrolls with masks. " \
                 "From then on the agent dials xixo, reports the machine's health, and shares the folders " \
                 "listed here. The SSH key is used for that one install and then dropped.",
          names: "A name for the machine",
          fields: [
            field("host", "Address", required: true, placeholder: "100.64.0.5",
                  help: "Where xixo reaches its SSH server. Through a tailnet, its address on the tailnet."),
            field("port", "SSH port", kind: "integer", value: "22"),
            field("user", "SSH user", required: true, placeholder: "jon",
                  help: "The agent runs as this user and reads only what it can read. The user needs sudo " \
                        "without a password to install it."),
            field("private_key", "SSH private key", kind: "text", secret: true,
                  help: "Used once to install the agent and then dropped, whether the install worked or not. " \
                        "Paste it again to install again."),
            field("host_key", "Host key", placeholder: "SHA256:…",
                  help: "The SHA256 fingerprint of the machine's SSH host key. Left empty, the key seen on the " \
                        "first install is kept, and every later install must meet the same one."),
            field("folders", "Folders it shares", kind: "lines", placeholder: "/srv/media",
                  help: "Absolute paths, one per line. The agent reads nothing outside them, and only an install " \
                        "or the machine's own config changes them.")
          ]
        }
      end

      def command_schema
        { health: {}, discover: {} }
      end

      def routable?
        true
      end

      def enrolled(client_id)
        return nil if client_id.blank?

        active.find_by("resources.details ->> 'client_id' = ?", client_id.to_s)
      end

      def binaries
        Pathname.new(ENV.fetch("XIXO_AGENT_DIR", "/opt/xixo-agent"))
      end
    end

    def machine
      details.to_h["machine"].to_h
    end

    def client_id
      details.to_h["client_id"]
    end

    def offered_folders
      Array(machine["folders"])
    end

    def seen_at
      Time.iso8601(machine["seen_at"].to_s)
    rescue ArgumentError
      nil
    end

    def connected?
      machine["connected"] == true && seen_at.present? && seen_at > QUIET_AFTER.ago
    end

    def installing?
      Run.open.exists?(resource_id: id, kind: "install")
    end

    def check!
      return true if installing? || connected?
      raise Resource::Failed, "#{key}: the agent is not installed yet. Paste an SSH key to install it" if client_id.blank?
      raise Resource::Failed, "#{key}: the agent has never connected" if seen_at.nil?

      raise Resource::Failed, "#{key}: the agent was last heard from #{seen_at.utc.iso8601}"
    end

    def carries?(resource)
      resource.is_a?(AgentFolder)
    end

    def reach!(_target)
      raise Resource::Refused, "#{key} reaches only the folders its agent shares"
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
          "services" => [ { "name" => "folder", "port" => 0, "type" => AgentFolder.sti_name, "address" => path } ]
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
      AgentExchange.where(id: exchange.id).delete_all if exchange
    end

    def read(folder, path, within: ANSWERED_WITHIN)
      exchanged("read", { "folder" => folder, "path" => path }, within: within) do |answer|
        Reading.new(self, answer.exchange, size: answer.result.to_h["size"]).file
      end
    end

    def upload(io, within: ANSWERED_WITHIN)
      exchange = asked(nil, nil)
      size = 0
      seq = 0

      while (part = io.read(MOST_CHUNKED))
        size += part.bytesize
        raise Resource::Failed, "#{key}: an upload is larger than #{AgentExchange::MOST_RECEIVED} bytes" if size > AgentExchange::MOST_RECEIVED

        put(exchange, "seq" => seq, "data" => Base64.strict_encode64(part))
        seq += 1
      end

      put(exchange, "done" => true, "size" => size)
      held = awaited(exchange, "put", within).to_h["size"]
      raise Resource::Failed, "#{key}: the agent kept #{held.inspect} bytes of #{size}" unless held == size

      exchange.request
    ensure
      AgentExchange.where(id: exchange.id).delete_all if exchange
    end

    def waiting
      sleep POLLED_EVERY
    end

    def greeted!(said, session:)
      merge_machine!(Hello.from(said).merge("session" => session, "connected" => true, "seen_at" => now_stamp))
      update_columns(offline_host: nil, offline_last_seen_at: nil, checked_at: Time.current, check_error: nil)
    end

    def heard!(said)
      merge_machine!("health" => Health.from(said), "seen_at" => now_stamp)
    end

    def parted!(session:)
      Resource.where(id: id)
              .where("resources.details -> 'machine' ->> 'session' = ?", session.to_s)
              .update_all([ <<~SQL.squish, now_stamp, machine["hostname"].presence || key, Time.current ])
                details = jsonb_set(details, '{machine}', (details -> 'machine') || jsonb_build_object('connected', false, 'seen_at', ?::text)),
                offline_host = ?, offline_last_seen_at = ?
              SQL
    end

    def enrolled!(client_id:, host_key:, version:, arch:)
      self.details = details.to_h.merge(
        "client_id" => client_id, "host_key" => host_key,
        "installed" => { "version" => version, "arch" => arch, "at" => now_stamp }
      )
      save!
    end

    def unenroll!(revoker: Enrollment.method(:revoke))
      return if client_id.blank?

      revoker.call(tenant, client_id)
      self.details = unenrolled_details
      save!
    end

    def forget_key!
      return if credentials.to_h["private_key"].blank?

      self.credentials = credentials.to_h.except("private_key")
      save!
    end

    def install_later
      run = Run.start!(kind: "install", resource: self)
      InstallAgentJob.perform_later(id, run.id)
    end

    private

      def shared_by_everyone
        errors.add(:owner_subject, "cannot be set on a machine, which an administrator attaches for everyone") if personal?
      end

      def put_away?
        will_save_change_to_archived_at? && archived_at.present? && client_id.present?
      end

      def put_away_now?
        destroyed? || (saved_change_to_archived_at? && archived_at.present?)
      end

      def unenroll
        Enrollment.revoke(tenant, client_id)
        self.details = unenrolled_details
      rescue Resource::Failed => e
        errors.add(:base, "#{e.message}, so #{key} stays attached and its agent keeps signing in. Try again once masks answers")
        throw :abort
      end

      def unenrolled_details
        details.to_h.except("client_id").merge("unenrolled" => { "client_id" => client_id, "at" => now_stamp })
      end

      def hang_up
        ActionCable.server.remote_connections.where(tenant: tenant, grant: nil, machine: self).disconnect(reconnect: false)
      end

      def key_given?
        saved_change_to_credentials? && credentials.to_h["private_key"].present?
      end

      def asked(verb, args)
        raise Resource::Offline, "#{key}: the agent is not connected" unless connected?

        AgentExchange.create!(resource: self, request: SecureRandom.uuid, verb: verb || "put").tap do |exchange|
          AgentChannel.broadcast_to(self, { "request" => exchange.request, "verb" => verb, "args" => args.presence || {} }) if verb
        end
      end

      def put(exchange, args)
        AgentChannel.broadcast_to(self, { "request" => exchange.request, "verb" => "put", "args" => args })
      end

      def awaited(exchange, verb, within)
        deadline = within.from_now

        loop do
          held = AgentExchange.uncached { AgentExchange.find(exchange.id) }
          return held.result if held.answered?
          raise Resource::Failed, "#{key}: the agent said #{held.error}" if held.refused?

          if Time.current > deadline
            held.refuse!("no answer in #{within.inspect}")
            raise Resource::Failed, "#{key}: the agent did not answer #{verb} in #{within.inspect}"
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
