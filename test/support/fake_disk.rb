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
      fake_disk? ? Resource::XixoAgent::EXTRACTORS : super
    end

    def exchanged(verb, args = {}, within: nil, &block)
      return super(verb, args, **{ within: within }.compact, &block) unless fake_disk?

      FakeDisk.exchanged(self, verb.to_s, args.to_h.deep_stringify_keys, &block)
    end

    def ask(verb, args = {}, within: nil)
      return super(verb, args, **{ within: within }.compact) unless fake_disk?

      FakeDisk.answer(self, verb.to_s, args.to_h.stringify_keys)
    end

    def read(folder, path, within: nil)
      return super(folder, path, **{ within: within }.compact) unless fake_disk?

      FakeDisk.read(self, folder, path)
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
    def disk_agent(folders:, writable: folders, key: "disk")
      folders = folders.map(&:to_s)
      writable = writable.map(&:to_s)
      held = Resource::XixoAgent.find_by(key: key)
      machine = { "hostname" => key, "connected" => true, "session" => "disk", "seen_at" => Time.current.utc.iso8601 }

      if held
        known = held.machine
        machine = known.merge(machine).merge("folders" => (Array(known["folders"]) | folders).sort,
                                             "writable" => (Array(known["writable"]) | writable).sort)
        held.update!(details: held.details.merge("machine" => machine))
        return held
      end

      Resource::XixoAgent.create!(
        key: key, name: key.titleize,
        details: { MARK => true, "client_id" => "disk-#{SecureRandom.hex(4)}",
                   "machine" => machine.merge("folders" => folders.sort, "writable" => writable.sort) }
      )
    end

    def disk_folder(path, key:, name: nil, writable: true, **attributes)
      path = Pathname.new(path).expand_path.to_s
      agent = disk_agent(folders: [ path ], writable: writable ? [ path ] : [])

      Resource::Filesystem.create!(key: key, name: name || key.titleize, via: agent,
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

    def answer(agent, verb, args)
      case verb
      when "list" then listed(agent, args)
      when "write" then written(agent, args)
      when "hash" then hashed(agent, args)
      when "health" then {}
      else refuse(agent, "the agent does not know the verb #{verb.inspect}")
      end
    end

    def exchanged(agent, verb, args)
      source = args["source"].to_h
      return yield(FakeAgent::Answer.new(answer(agent, verb, args), {})) if source["folder"].blank?

      bytes = confined(agent, source["folder"], source["path"]).binread
      staged = FakeAgent.upload(StringIO.new(bytes))
      answered = FakeAgent.answer(verb, args.merge("source" => { "upload" => staged["upload"] }))
      result = answered.result.merge("sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize)

      yield FakeAgent::Answer.new(result, answered.instance_variable_get(:@held))
    end

    def read(agent, folder, path)
      target = confined(agent, folder, path)
      refuse(agent, "no such file") unless target.file?

      Tempfile.new("fake-disk", binmode: true).tap do |file|
        file.write(target.binread)
        file.rewind
      end
    end

    private

      def listed(agent, args)
        root = shared(agent, args["folder"])
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

      def hashed(agent, args)
        bytes = confined(agent, args["folder"], args["path"]).binread

        { "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
      end

      def written(agent, args)
        folder = args["folder"].to_s
        shared(agent, folder)
        refuse(agent, "that folder is shared read-only") unless agent.writable_folders.include?(folder)

        target = confined(agent, folder, args["path"], creating: true)
        bytes = staged.fetch(args["upload"].to_s) { refuse(agent, "xixo answered the upload with 404 Not Found") }
        refuse(agent, "the upload's size does not match what arrived") unless bytes.bytesize == args["size"].to_i
        refuse(agent, "a file is already at that path") if target.exist? && !args["replace"]

        target.dirname.mkpath
        target.binwrite(bytes)
        stat = target.lstat

        { "path" => args["path"], "size" => stat.size, "modified_at" => stat.mtime.utc.iso8601 }
      end

      def shared(agent, folder)
        refuse(agent, "that folder is not shared by this machine") unless agent.offered_folders.include?(folder.to_s)

        Pathname.new(folder.to_s)
      end

      def confined(agent, folder, path, creating: false)
        root = shared(agent, folder)
        held = path.to_s
        parts = held.split("/")

        if held.empty? || held.start_with?("/") || parts.any? { |part| part.empty? || part.in?(%w[. ..]) }
          refuse(agent, "that path is outside the folder")
        end

        refuse(agent, "that path is never shared") if parts.any? { |part| SKIPPED.any? { |pattern| File.fnmatch(pattern, part, File::FNM_DOTMATCH) } }

        walked = root
        parts.each do |part|
          walked += part
          refuse(agent, "that path is outside the folder: #{part} is a link") if walked.symlink?
        end

        refuse(agent, "no such file") unless creating || walked.exist?
        walked
      end

      def refuse(agent, said)
        raise Resource::XixoAgent::Refusal, "#{agent.key}: the agent said #{said}"
      end
  end
end

Resource::XixoAgent.prepend(FakeDisk::Broker)
