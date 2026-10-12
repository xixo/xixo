class Resource
  class AgentFolder < Resource
    PAGE = 500
    LOOKED_AT = 10

    validate :reached_through_an_agent
    validate :folder_is_shared, if: -> { new_record? || will_save_change_to_details? || will_save_change_to_via_id? }

    class << self
      def attaching
        {
          label: "A folder on a machine",
          blurb: "A folder the xixo agent on a machine shares. xixo asks the agent for what is in it, and the " \
                 "agent reads nothing outside the folders its own config lists.",
          names: "A name for the folder",
          fields: [
            field("folder", "Folder", required: true, placeholder: "/srv/media",
                  help: "One of the folders the machine's agent shares."),
            field("prefix", "Prefix", help: "Left off, the whole folder is walked."),
            field("skip", "Also skip", kind: "list", placeholder: "*.tmp",
                  help: "A name or a pattern such as build or *.tmp on each line. Folders and files with a " \
                        "matching name are never walked.")
          ]
        }
      end

      def command_schema
        {
          list: { prefix: "string?", limit: "integer?" },
          get: { key: "string" },
          keep: { key: "string" }
        }
      end

      def routable?
        true
      end

      def addressed_by
        "folder"
      end

      def address_on(host, port: nil)
        host
      end
    end

    def agent
      via if via.is_a?(XixoAgent)
    end

    def folder
      details.to_h["folder"].to_s
    end

    def target_host
      agent && (agent.machine["hostname"].presence || agent.key)
    end

    def answers!
      shared!
      raise Resource::Failed, "#{key}: the agent on #{agent.key} is not connected" unless agent.connected?

      true
    end

    def probes?
      true
    end

    def check!
      answers!
      agent.ask("list", { "folder" => folder, "limit" => 1 })
      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      shared!
      wanted = within_prefix(prefix, bounded: true)
      after = cursor.presence

      loop do
        entries, more = listed(prefix: wanted, cursor: after, limit: PAGE)
        break if entries.empty?

        after = entries.last.path
        yield entries, after
        break unless more
      end
    end

    def object_for(name)
      path = scoped(name)
      found, = listed(prefix: path, limit: LOOKED_AT)

      found.find { |entry| entry.path == path } || raise(Resource::Failed, "#{key}: no file at #{path}")
    end

    def locator_for(entry)
      { "path" => entry.path, "size" => entry.size, "modified_at" => entry.modified_at.utc.iso8601 }
    end

    def locator_key_for(entry)
      entry.path
    end

    def version_for(locator)
      modified_at = locator.to_h["modified_at"]
      return nil if modified_at.blank?

      [ modified_at, locator.to_h["size"] ].compact.join(":")
    end

    def download(locator)
      shared!
      agent.read(folder, relative!(locator.to_h["path"]))
    end

    def digest_of(locator)
      shared!
      Fingerprint.reported(agent.ask("hash", { "folder" => folder, "path" => relative!(locator.to_h["path"]) }))
    end

    def command_list(prefix: nil, limit: nil)
      shared!
      count = (limit || 1000).to_i.clamp(1, PAGE)
      entries, = listed(prefix: within_prefix(prefix, bounded: true), limit: count)

      { "objects" => entries.map { |entry| { "key" => entry.path, "size" => entry.size, "last_modified" => entry.modified_at } } }
    end

    def command_get(key:)
      file = download(locator_for(object_for(key)))

      glimpse(key, file.read(GLIMPSE_BYTES), file.size)
    ensure
      file&.close!
    end

    def command_keep(key:) = kept(key)

    private

      Entry = Data.define(:path, :size, :modified_at)

      def listed(prefix: nil, cursor: nil, limit: PAGE)
        asked = { "folder" => folder, "limit" => limit, "prefix" => prefix.presence, "cursor" => cursor,
                  "skip" => Array(details.to_h["skip"]).presence }.compact
        held = agent.ask("list", asked).to_h

        entries = Array(held["entries"]).first(limit).map { |entry| entry_from(entry) }
        [ entries, held["cursor"].present? ]
      end

      def entry_from(said)
        raise Resource::Failed, "#{key}: the agent listed something that is not a file" unless said.is_a?(Hash)

        size = said["size"]
        raise Resource::Failed, "#{key}: the agent listed a file without a size" unless size.is_a?(Integer) && size >= 0

        Entry.new(path: relative!(said["path"]), size: size, modified_at: Time.iso8601(said["modified_at"].to_s))
      rescue ArgumentError
        raise Resource::Failed, "#{key}: the agent listed a file without a time"
      end

      def scoped(name)
        within_prefix(relative!(name), bounded: true)
      end

      def relative!(path)
        held = path.to_s
        parts = held.split("/")

        if held.empty? || held.bytesize > XixoAgent::MOST_PATH || held.start_with?("/") || held.include?("\0") ||
           !held.valid_encoding? || parts.any? { |part| part.empty? || part.in?(%w[. ..]) }
          raise Resource::Failed, "#{key}: #{held.first(80).inspect} is not a path inside the folder"
        end

        held
      end

      def shared!
        raise Resource::Unusable, "#{key} is reached through no agent" if agent.nil?
        return if agent.offered_folders.include?(folder)

        raise Resource::Unusable, "#{key}: the agent on #{agent.key} no longer shares #{folder}"
      end

      def reached_through_an_agent
        return if via.is_a?(XixoAgent)

        errors.add(:via, "must be a machine with the xixo agent, which is the only way to reach its folders")
      end

      def folder_is_shared
        return unless via.is_a?(XixoAgent)
        return if via.offered_folders.include?(folder)

        offered = via.offered_folders
        errors.add(:folder, "#{folder} is not one the agent on #{via.key} shares. " \
                            "#{offered.any? ? "It shares #{offered.to_sentence}" : 'It shares nothing yet'}")
      end
  end
end
