class Resource
  class Filesystem < Resource
    PAGE = 500
    LOOKED_AT = 10
    MOST_CHANGED = 256
    MOST_LOOKED_AGAIN = 2_000
    WRITTEN_WITHIN = 30.seconds
    WRITTEN_PER_MEGABYTE = 1.second
    MOST_WRITTEN_WITHIN = 1.hour
    TENANT = "%{tenant}".freeze

    serves :storage
    accepts "*/*"

    validate :reached_through_a_machine
    validate :folder_is_shared, if: -> { new_record? || will_save_change_to_details? || will_save_change_to_via_id? }
    validate :folder_is_not_anothers, if: -> { new_record? || will_save_change_to_details? || will_save_change_to_via_id? || will_save_change_to_owner_subject? }

    class << self
      def attaching
        {
          label: "A folder",
          blurb: "A folder on a machine running xixo link, the server's own included. xixo link reads " \
                 "nothing outside the folders its config shares, and writes only to the ones it marks writable.",
          names: "A name for the folder",
          fields: [
            field("folder", "Folder", required: true, placeholder: "/data/files",
                  help: "One of the folders xixo link on the machine shares."),
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
          keep: { key: "string" },
          put: { key: "string", body: "bytes" }
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

      def inside?(path)
        return false unless path.is_a?(String) && path.valid_encoding?
        return false if path.empty? || path.bytesize > Machine::MOST_PATH || path.start_with?("/") || path.include?("\0")

        path.split("/").none? { |part| part.empty? || part.in?(%w[. ..]) }
      end

      def declared_folder(folder, tenant)
        folder.to_s.gsub(TENANT, tenant.subdomain)
      end
    end

    def machine
      via if via.is_a?(Machine)
    end

    def folder
      details.to_h["folder"].to_s
    end

    def writable?
      machine.present? && machine.writable_folders.include?(folder)
    end

    def served
      return super unless machine&.heard_from? && !writable?

      super.merge("accepts" => [])
    end

    def target_host
      machine && (machine.machine["hostname"].presence || machine.key)
    end

    def answers!
      shared!
      raise Resource::Failed, "#{key}: #{machine.key} is not connected" unless machine.connected?

      true
    end

    def probes?
      true
    end

    def check!
      answers!
      machine.ask("list", { "folder" => folder, "limit" => 1 })
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

    def changed_later!(paths, everything: false)
      return sync! if everything

      SyncPathsJob.perform_later(tenant_id, id, paths) if paths.any?
    rescue ArgumentError
      nil
    end

    def looked_again!(paths)
      shared!
      paths.first(MOST_CHANGED).each do |path|
        break unless looked_again(path)
      end
    end

    def download(locator)
      shared!
      machine.read(folder, relative!(locator.to_h["path"]))
    end

    def digest_of(locator)
      shared!
      Fingerprint.reported(machine.ask("hash", { "folder" => folder, "path" => relative!(locator.to_h["path"]) }))
    end

    def upload(name, body)
      shared!
      raise Resource::Refused, "#{key}: #{machine.key} shares #{folder} read-only" unless writable?

      path = relative!(name.to_s)
      staged = machine.upload(body.respond_to?(:read) ? body : StringIO.new(body.to_s))

      begin
        written = machine.ask("write", staged.merge("folder" => folder, "path" => path, "replace" => ours?(path)),
                            within: writing_within(staged["size"]))
      ensure
        machine.forget(staged["upload"])
      end

      locator_for(entry_from(written))
    end

    def command_list(prefix: nil, limit: nil)
      shared!
      count = (limit || 1000).to_i.clamp(1, PAGE)
      entries, = listed(prefix: within_prefix(prefix, bounded: true), limit: count)

      { "objects" => entries.map { |entry| { "key" => entry.path, "size" => entry.size, "last_modified" => entry.modified_at } } }
    end

    def command_get(key:)
      shared!
      path = relative!(locator_for(object_for(key))["path"])
      bytes, size = machine.glimpse(folder, path, limit: GLIMPSE_BYTES)

      glimpse(key, bytes, size)
    end

    def command_keep(key:) = kept(key)

    def command_put(key:, body:)
      upload(scoped(key), body)
    end

    Entry = Data.define(:path, :size, :modified_at)

    private

      def looked_again(asked)
        path = scoped(asked)
        found = beneath(path)

        if found.nil?
          sync!
          return false
        end

        found.each { |entry| keep!(entry) }
        Reference.originals.where(resource_id: id, gone_at: nil)
                 .where("locator_key = ? OR locator_key LIKE ?", path, "#{Reference.sanitize_sql_like(path)}/%")
                 .where.not(locator_key: found.map(&:path))
                 .update_all(gone_at: Time.current)
        true
      rescue ArgumentError
        true
      end

      def beneath(path)
        found = []
        after = nil

        loop do
          entries, more = listed(prefix: path, cursor: after, limit: PAGE)
          found.concat(entries.select { |entry| entry.path == path || entry.path.start_with?("#{path}/") })
          return nil if found.size > MOST_LOOKED_AGAIN
          break if !more || entries.empty?

          after = entries.last.path
        end

        found
      end

      def listed(prefix: nil, cursor: nil, limit: PAGE)
        asked = { "folder" => folder, "limit" => limit, "prefix" => prefix.presence, "cursor" => cursor,
                  "skip" => Array(details.to_h["skip"]).presence }.compact
        held = machine.ask("list", asked).to_h

        entries = Array(held["entries"]).first(limit).map { |entry| entry_from(entry) }
        [ entries, held["cursor"].present? ]
      end

      def entry_from(said)
        raise Resource::Failed, "#{key}: xixo link listed something that is not a file" unless said.is_a?(Hash)

        size = said["size"]
        raise Resource::Failed, "#{key}: xixo link listed a file without a size" unless size.is_a?(Integer) && size >= 0

        Entry.new(path: relative!(said["path"]), size: size, modified_at: Time.iso8601(said["modified_at"].to_s))
      rescue ArgumentError
        raise Resource::Failed, "#{key}: xixo link listed a file without a time"
      end

      def ours?(path)
        Reference.exists?(resource_id: id, locator_key: path)
      end

      def writing_within(size)
        megabytes = size.to_i.fdiv(1.megabyte).ceil

        [ WRITTEN_WITHIN + (WRITTEN_PER_MEGABYTE * megabytes), MOST_WRITTEN_WITHIN ].min
      end

      def scoped(name)
        within_prefix(relative!(name), bounded: true)
      end

      def relative!(path)
        held = path.to_s
        return held if Filesystem.inside?(held)

        raise Resource::Failed, "#{key}: #{held.first(80).inspect} is not a path inside the folder"
      end

      def shared!
        raise Resource::Unusable, "#{key} is reached through no machine" if machine.nil?
        return if !machine.heard_from? || machine.offered_folders.include?(folder)

        said = "#{key}: #{machine.key} no longer shares #{folder}"
        record_check(said) if persisted?
        raise Resource::Unusable, said
      end

      def reached_through_a_machine
        return if via.is_a?(Machine)

        errors.add(:via, "must be a machine running xixo link, which is the only way to reach its folders")
      end

      def folder_is_not_anothers
        return unless via.is_a?(Machine) && folder.start_with?("/")

        held = Filesystem.where(via_id: via_id).where.not(id: id).find do |other|
          other.owner_subject != owner_subject && nested?(other.folder, folder)
        end
        return if held.nil?

        errors.add(:folder, "#{folder} overlaps #{held.folder}, which another folder on #{via.key} holds for " \
                            "#{held.personal? ? 'one person' : 'everyone'}. Each folder on a machine is held for " \
                            "one owner")
      end

      def nested?(one, other)
        a, b = [ one, other ].map { |path| path.delete_suffix("/").presence || "/" }

        a == b || [ [ a, b ], [ b, a ] ].any? { |outer, inner| outer == "/" || inner.start_with?("#{outer}/") }
      end

      def folder_is_shared
        return unless via.is_a?(Machine)

        errors.add(:folder, "must be an absolute path") unless folder.start_with?("/")
        return if !via.heard_from? || via.offered_folders.include?(folder)

        offered = via.offered_folders
        errors.add(:folder, "#{folder} is not one #{via.key} shares. " \
                            "#{offered.any? ? "It shares #{offered.to_sentence}" : 'It shares nothing yet'}")
      end
  end
end
