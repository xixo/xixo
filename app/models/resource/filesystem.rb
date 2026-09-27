require "pathname"

class Resource
  class Filesystem < Resource
    class Escaped < Resource::Failed; end

    PAGE = 500

    serves :storage
    accepts "*/*"

    def self.attaching
      return nil if permitted_roots.empty?

      {
        label: "A directory",
        blurb: "A directory on the machine running uris, inside this tenant's own directory under " \
               "a root the server was started with. A relative path is taken from there.",
        names: "A name for it",
        fields: [
          field("root", "Directory", required: true, placeholder: "photos"),
          field("prefix", "Prefix", help: "Left off, the whole directory is walked.")
        ]
      }
    end

    def self.command_schema
      {
        list: { prefix: "string?", limit: "integer?" },
        get: { key: "string" },
        keep: { key: "string" },
        put: { key: "string", body: "bytes" }
      }
    end

    def self.permitted_roots
      ENV.fetch("URIS_FILESYSTEM_ROOTS", "").split(":").filter_map do |entry|
        Pathname.new(entry.strip).expand_path if entry.strip.present?
      end
    end

    def self.spaces_for(tenant)
      return [] if tenant.nil?

      permitted_roots.map { |permitted| permitted + tenant.subdomain }
    end

    def spaces
      self.class.spaces_for(tenant)
    end

    def root
      @root ||= begin
        given = Pathname.new(details.fetch("root").to_s)

        if given.absolute? || spaces.empty?
          given.expand_path
        else
          (spaces.first + given).cleanpath
        end
      end
    end

    def check!
      permitted_root!
      raise Resource::Failed, "#{key}: #{root} is not a readable directory" unless root.directory? && root.readable?

      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      permitted_root!
      @walk = walk

      walk(prefix).drop_while { |path| cursor.present? && !after?(path, cursor) }
                  .each_slice(PAGE) do |batch|
        yield batch.map { |path| entry(path) }, batch.last
      end
    end

    def object_for(name)
      permitted_root!

      path = within_prefix(lexical(name).relative_path_from(root.cleanpath).to_s)

      resolved = confine(path)

      raise Resource::Failed, "#{key}: no file at #{path}" unless resolved == resolve(root) + path && resolved.file?

      entry(path)
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
      permitted_root!
      File.open(confine(locator.fetch("path")), "rb")
    rescue Errno::ENOENT
      raise Resource::Failed, "#{key}: nothing at #{locator['path']}"
    rescue SystemCallError => e
      raise Resource::Failed, "#{key}: #{e.message}"
    end

    def upload(name, body)
      permitted_root!
      target = confine_for_write(name)
      target.dirname.mkpath
      confine_for_write(name)

      File.open(target, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW | File::BINARY) do |file|
        body.respond_to?(:read) ? IO.copy_stream(body, file) : file.write(body.to_s)
      end

      { "path" => relative(target) }
    rescue Errno::ELOOP
      escaped!(name)
    rescue SystemCallError => e
      raise Resource::Failed, "#{key}: #{e.message}"
    end

    def command_list(prefix: nil, limit: nil)
      permitted_root!
      count = (limit || 1000).to_i.clamp(1, 5000)

      {
        "objects" => walk(prefix).first(count).map do |path|
          found = entry(path)
          { "key" => found.path, "size" => found.size, "last_modified" => found.modified_at }
        end
      }
    end

    def command_get(key:)
      file = download(locator_for(object_for(key)))

      glimpse(key, file.read(GLIMPSE_BYTES), file.size)
    ensure
      file&.close
    end

    def command_keep(key:) = kept(key)

    def command_put(key:, body:)
      permitted_root!
      upload(within_prefix(lexical(key).relative_path_from(root.cleanpath).to_s), body)
    end

    private

      Entry = Data.define(:path, :size, :modified_at)

      def entry(path)
        stat = confine(path).lstat

        Entry.new(path: path, size: stat.size, modified_at: stat.mtime)
      end

      def permitted_root!
        if self.class.permitted_roots.empty?
          raise Resource::Failed,
                "#{key}: no filesystem roots are permitted — set URIS_FILESYSTEM_ROOTS"
        end

        space = spaces.find { |held| under?(root, held) }
        raise Escaped, "#{key}: #{root} is outside every permitted filesystem root" if space.nil?

        space.mkpath
        return true if !root.exist? || under?(resolve(root), resolve(space))

        raise Escaped, "#{key}: #{root} is outside every permitted filesystem root"
      end

      def confine(path)
        resolved = resolve(lexical(path))
        escaped!(path) unless under?(resolved, resolve(root))

        resolved
      end

      def confine_for_write(path)
        candidate = lexical(path)
        anchor = resolve(nearest_existing(candidate.dirname))
        escaped!(path) unless under?(anchor, resolve(root))

        candidate
      end

      def lexical(path)
        candidate = (root + path.to_s).cleanpath
        escaped!(path) unless under?(candidate, root.cleanpath)

        candidate
      end

      def nearest_existing(path)
        path = path.parent until path.exist? || path.root?
        path
      end

      def escaped!(path)
        raise Escaped, "#{key}: #{path} resolves outside #{root}"
      end

      def resolve(path)
        Pathname.new(File.realpath(path))
      rescue Errno::ENOENT, Errno::ELOOP, SystemCallError
        raise Resource::Failed, "#{key}: cannot resolve #{relative(path)}"
      end

      def under?(path, ancestor)
        path == ancestor || path.to_s.start_with?("#{ancestor}#{File::SEPARATOR}")
      end

      def relative(path)
        Pathname.new(path).relative_path_from(root).to_s
      rescue ArgumentError
        path.to_s
      end

      def after?(path, cursor)
        (path.to_s.split("/") <=> cursor.to_s.split("/")).to_i.positive?
      end

      def within_prefix(asked)
        wanted = details["prefix"].presence
        return asked.presence || wanted if wanted.nil? || asked.to_s.start_with?(wanted)

        raise ArgumentError, "#{key}: #{asked} is outside #{wanted}"
      end

      def walk(prefix = nil)
        wanted = within_prefix(prefix)

        Enumerator.new do |yielder|
          descend(root, "", yielder)
        end.lazy.select { |path| wanted.nil? || path.start_with?(wanted) }
      end

      def descend(directory, prefix, yielder)
        directory.children.sort_by(&:basename).each do |child|
          next if child.symlink?

          name = prefix.empty? ? child.basename.to_s : File.join(prefix, child.basename.to_s)

          if child.directory?
            descend(child, name, yielder)
          elsif child.file?
            yielder.yield(name)
          end
        end
      rescue SystemCallError
        @walk&.partial!
        nil
      end
  end
end
