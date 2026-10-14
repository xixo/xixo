module FakeDisk
  MARK = "fake_disk".freeze
  SKIPPED = %w[
    .git .hg .svn node_modules __pycache__ .venv .tox .Trash .Trashes .Spotlight-V100 .fseventsd
    .DS_Store ._* Thumbs.db desktop.ini .xixo-*.part
  ].freeze

  module Broker
    def fake_disk?
      details.to_h[MARK] == true
    end

    def connected?
      fake_disk? || super
    end

    def extracts?(kind)
      fake_disk? || super
    end

    def extractors
      fake_disk? ? Resource::Machine::EXTRACTORS : super
    end

    def exchanged(verb, args = {}, **, &block)
      return super unless fake_disk?

      FakeDisk.exchanged(self, verb.to_s, args.to_h.deep_stringify_keys, &block)
    end

    def ask(verb, args = {}, **)
      return super unless fake_disk?

      FakeDisk.answer(self, verb.to_s, args.to_h.stringify_keys)
    end

    def read(folder, path, **)
      return super unless fake_disk?

      FakeDisk.read(self, folder, path)
    end

    def glimpse(folder, path, limit:, **)
      return super unless fake_disk?

      FakeDisk.glimpse(self, folder, path, limit)
    end

    def upload(io)
      return super unless fake_disk?

      FakeDisk.stage(io)
    end

    def forget(request)
      return super unless fake_disk?

      FakeDisk.staged.delete(request.to_s)
    end
  end

  module Helpers
    def disk_machine(folders:, writable: folders, key: "disk")
      folders = folders.map(&:to_s)
      writable = writable.map(&:to_s)
      held = Resource::Machine.find_by(key: key)
      machine = { "hostname" => key, "connected" => true, "session" => "disk", "seen_at" => Time.current.utc.iso8601,
                  "tools" => Resource::Machine::Tools::NAMES, "lend" => true, "extracts_for_others" => true }

      if held
        known = held.machine
        machine = known.merge(machine).merge("folders" => (Array(known["folders"]) | folders).sort,
                                             "writable" => (Array(known["writable"]) | writable).sort)
        held.update!(details: held.details.merge("machine" => machine))
        return held
      end

      Resource::Machine.create!(
        key: key, name: key.titleize,
        details: { MARK => true, "client_id" => "disk-#{SecureRandom.hex(4)}",
                   "machine" => machine.merge("folders" => folders.sort, "writable" => writable.sort) }
      )
    end

    def disk_folder(path, key:, name: nil, writable: true, **attributes)
      path = Pathname.new(path).expand_path.to_s
      machine = disk_machine(folders: [ path ], writable: writable ? [ path ] : [])

      Resource::Filesystem.create!(key: key, name: name || key.titleize, via: machine,
                                   details: { "folder" => path }.merge(attributes.delete(:details).to_h), **attributes)
    end
  end

  class << self
    def staged
      @staged ||= {}
    end

    def stage(io)
      id = SecureRandom.uuid
      staged[id] = io.read.to_s.b

      { "upload" => id, "size" => staged[id].bytesize }
    end

    def answer(machine, verb, args)
      case verb
      when "list" then listed(machine, args)
      when "write" then written(machine, args)
      when "hash" then hashed(machine, args)
      when "health" then {}
      else refuse(machine, "xixo link does not know the verb #{verb.inspect}")
      end
    end

    def exchanged(machine, verb, args)
      source = args["source"].to_h
      return yield(FakeLink::Answer.new(answer(machine, verb, args), {})) if source["folder"].blank?

      bytes = confined(machine, source["folder"], source["path"]).binread
      staged = FakeLink.upload(StringIO.new(bytes))
      answered = FakeLink.answer(verb, args.merge("source" => { "upload" => staged["upload"] }))
      result = answered.result.merge("sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize)

      yield FakeLink::Answer.new(result, answered.instance_variable_get(:@held))
    end

    def glimpse(machine, folder, path, limit)
      target = confined(machine, folder, path)
      refuse(machine, "no such file") unless target.file?

      [ File.binread(target, limit).to_s, target.size ]
    end

    def read(machine, folder, path)
      target = confined(machine, folder, path)
      refuse(machine, "no such file") unless target.file?

      Tempfile.new("fake-disk", binmode: true).tap do |file|
        file.write(target.binread)
        file.rewind
      end
    end

    private

      def listed(machine, args)
        root = shared(machine, args["folder"])
        skip = SKIPPED + Array(args["skip"])
        prefix = args["prefix"].to_s
        after = args["cursor"].presence
        limit = (args["limit"] || 500).to_i.clamp(1, 500)
        entries = []
        more = false

        walk(root, "", skip) do |name, stat|
          next unless name.start_with?(prefix)
          next if after && (name.split("/") <=> after.split("/")) <= 0

          if entries.size == limit
            more = true
            break
          end

          entries << { "path" => name, "size" => stat.size, "modified_at" => stat.mtime.utc.iso8601 }
        end

        { "entries" => entries, "cursor" => (more ? entries.last["path"] : nil) }.compact
      end

      def walk(directory, prefix, skip, &block)
        directory.children.sort_by { |child| child.basename.to_s }.each do |child|
          base = child.basename.to_s
          next if child.symlink? || skip.any? { |pattern| File.fnmatch(pattern, base, File::FNM_DOTMATCH) }

          name = prefix.empty? ? base : "#{prefix}/#{base}"
          child.directory? ? walk(child, name, skip, &block) : (yield(name, child.lstat) if child.file?)
        end
      end

      def hashed(machine, args)
        bytes = confined(machine, args["folder"], args["path"]).binread

        { "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
      end

      def written(machine, args)
        folder = args["folder"].to_s
        shared(machine, folder)
        refuse(machine, "that folder is shared read-only") unless machine.writable_folders.include?(folder)

        target = confined(machine, folder, args["path"], creating: true)
        bytes = staged.fetch(args["upload"].to_s) { refuse(machine, "xixo answered the upload with 404 Not Found") }
        refuse(machine, "the upload's size does not match what arrived") unless bytes.bytesize == args["size"].to_i
        refuse(machine, "a file is already at that path") if target.exist? && !args["replace"]

        target.dirname.mkpath
        target.binwrite(bytes)
        stat = target.lstat

        { "path" => args["path"], "size" => stat.size, "modified_at" => stat.mtime.utc.iso8601 }
      end

      def shared(machine, folder)
        refuse(machine, "that folder is not shared by this machine") unless machine.offered_folders.include?(folder.to_s)

        Pathname.new(folder.to_s)
      end

      def confined(machine, folder, path, creating: false)
        root = shared(machine, folder)
        held = path.to_s
        parts = held.split("/")

        if held.empty? || held.start_with?("/") || parts.any? { |part| part.empty? || part.in?(%w[. ..]) }
          refuse(machine, "that path is outside the folder")
        end

        refuse(machine, "that path is never shared") if parts.any? { |part| SKIPPED.any? { |pattern| File.fnmatch(pattern, part, File::FNM_DOTMATCH) } }

        walked = root
        parts.each do |part|
          walked += part
          refuse(machine, "that path is outside the folder: #{part} is a link") if walked.symlink?
        end

        refuse(machine, "no such file") unless creating || walked.exist?
        walked
      end

      def refuse(machine, said)
        raise Resource::Machine::Refusal, "#{machine.key}: xixo link said #{said}"
      end
  end
end

Resource::Machine.prepend(FakeDisk::Broker)
