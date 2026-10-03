require "open3"

class Resource
  class Git < Resource
    HEAD = "refs/uris/head".freeze
    CHECKPOINT = "refs/uris/checkpoint".freeze
    NAMED = 200
    PAGE = 500
    MAX_BLOB = 2.megabytes
    DEFAULT_PROTOCOLS = "https".freeze
    TIMEOUT = 300
    ENTRY = /\A(\d+) (\w+) ([0-9a-f]+)\s+(\d+|-)\t(.+)\z/

    Entry = Data.define(:path, :sha, :size)

    def self.routable?
      true
    end

    def self.attaching
      {
        label: "A git repository",
        blurb: "Every file at the tip of one branch, each one an item. The clone is shallow " \
               "and bare — the history is not the catalogue.",
        names: "A name for it",
        fields: [
          field("url", "Repository URL", required: true,
                placeholder: "https://github.com/acme/widgets.git"),
          field("ref", "Branch", help: "The default branch unless you name another.",
                placeholder: "main"),
          field("token", "Access token", secret: true,
                help: "Only for a private repository. It travels through an askpass helper, " \
                      "never in the URL or the command line.")
        ]
      }
    end

    def self.command_schema
      {
        list: { prefix: "string?", limit: "integer?" },
        get: { path: "string" },
        keep: { path: "string" }
      }
    end

    def self.walks_changes?
      true
    end

    def self.root
      ENV["URIS_GIT_ROOT"].presence
    end

    def self.protocols
      ENV.fetch("URIS_GIT_PROTOCOLS", DEFAULT_PROTOCOLS).split(",").map(&:strip).compact_blank
    end

    validate :it_names_a_repository

    def url
      details.fetch("url", "").to_s.strip
    end

    def ref
      details["ref"].presence || "HEAD"
    end

    def working_dir
      root = self.class.root

      if root.blank?
        raise Resource::Unusable,
              "#{key}: no clone root is set — a server holding more than one tenant's catalogue " \
              "does not write clones wherever it likes. Set URIS_GIT_ROOT."
      end

      File.join(root, tenant_id.to_s, "#{Integer(id)}.git")
    end

    def check!
      pinned = permitted!

      refs = with_askpass do |env|
        git(*resolving(pinned), "ls-remote", "--heads", url, env: env, bare: true)
      end

      raise Resource::Failed, "#{key}: #{url} served no branches" if refs.strip.empty?

      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      since = walk&.since.to_h["commit"]
      prepare!
      kept = since.present? && holds?(since)
      git("update-ref", CHECKPOINT, since) if kept
      pull!
      walk&.reached({ "commit" => git("rev-parse", HEAD).strip }, first: true)

      found = if kept
        changed_since(since, prefix, walk)
      else
        walk&.start_over! if since.present?
        entries(prefix)
      end

      resumed = cursor.present? && found.index { |entry| entry.path == cursor }
      found = found.drop(resumed + 1) if resumed

      found.each_slice(PAGE) { |batch| yield batch, batch.last.path }
    end

    def object_for(path)
      pull!

      entries(path).find { |held| held.path == path } ||
        raise(Resource::Failed, "#{key}: no #{path} at #{ref}")
    end

    def locator_for(entry)
      { "path" => entry.path, "sha" => entry.sha, "size" => entry.size }
    end

    def locator_key_for(entry)
      entry.is_a?(Entry) ? entry.path : entry.to_s
    end

    def version_for(locator)
      locator.to_h["sha"].presence
    end

    def download(locator)
      sha = locator.fetch("sha")

      StringIO.new(git("cat-file", "blob", sha, binary: true))
    end

    def command_list(prefix: nil, limit: nil)
      pull!

      count = (limit || 100).to_i.clamp(1, PAGE)

      {
        "url" => url,
        "ref" => ref,
        "files" => entries(prefix).first(count).map { |entry| locator_for(entry) }
      }
    end

    def command_keep(path:) = kept(path)

    def command_get(path:)
      entry = object_for(path)

      locator_for(entry).merge("text" => download(locator_for(entry)).read.force_encoding("UTF-8").scrub)
    end

    private

      def entries(prefix)
        under = prefix.to_s.delete_prefix("/").chomp("/")
        wanted = under.present? ? [ "--", under ] : []
        listed = git("ls-tree", "-r", "-l", HEAD, *wanted)

        listed.lines.filter_map do |line|
          held = parsed(line)

          next if held.nil? || held.size > MAX_BLOB

          held
        end
      end

      def changed_since(since, prefix, walk)
        under = prefix.to_s.delete_prefix("/").chomp("/")
        said = git("diff", "--name-status", "--no-renames", "-z", since, HEAD, "--", *under.presence)
        changed = said.split("\0").each_slice(2).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

        walk.gone(changed.fetch("D", []))

        named = changed.except("D").values.flatten.sort
        named.each_slice(NAMED).flat_map { |paths| entries_named(paths) }.sort_by(&:path)
      end

      def entries_named(paths)
        git("ls-tree", "-l", HEAD, "--", *paths).lines.filter_map do |line|
          held = parsed(line)

          held if held && held.size <= MAX_BLOB
        end
      end

      def holds?(sha)
        return false unless sha.to_s.match?(/\A\h{40,64}\z/)

        git("cat-file", "-e", "#{sha}^{commit}")
        true
      rescue Resource::Failed
        false
      end

      def parsed(line)
        matched = ENTRY.match(line.chomp)

        return nil if matched.nil? || matched[2] != "blob"

        Entry.new(path: matched[5], sha: matched[3], size: matched[4].to_i)
      end

      def pull!
        pinned = permitted!
        prepare!

        with_askpass do |env|
          git(*resolving(pinned), "fetch", "--depth", "1", "--no-tags", url, "+#{ref}:#{HEAD}", env: env)
        end

        true
      end

      def prepare!
        return if File.directory?(File.join(working_dir, "objects"))

        FileUtils.mkdir_p(working_dir)
        git("init", "--bare", "--quiet", working_dir, bare: true)
      end

      # The token reaches git through a helper it executes rather than through the URL or the
      # command line, both of which any other process on the box can read.
      def with_askpass
        token = credentials["token"].presence

        return yield({}) if token.nil?

        Tempfile.create([ "askpass", ".sh" ]) do |file|
          file.write("#!/bin/sh\nprintf '%s' \"$URIS_GIT_TOKEN\"\n")
          file.close
          File.chmod(0o700, file.path)

          yield({ "GIT_ASKPASS" => file.path, "URIS_GIT_TOKEN" => token })
        end
      end

      def permitted!
        uri = URI.parse(url)

        if uri.userinfo.present?
          raise Resource::Unusable,
                "#{key}: a url carrying a name or token would show it to anyone who can list " \
                "this resource — put the token in its own field"
        end

        unless self.class.protocols.include?(uri.scheme)
          raise Resource::Unusable,
                "#{key}: #{uri.scheme.presence || 'that'} is not one of URIS_GIT_PROTOCOLS " \
                "(#{self.class.protocols.join(', ')})"
        end

        unless uri.is_a?(URI::HTTP)
          return nil if via.nil?

          raise Resource::Unusable, "#{key}: only an http or https url is reached through #{via.key}"
        end

        PublicAddress.pinned!(url, through: through)
      rescue URI::InvalidURIError
        raise Resource::Unusable, "#{key}: #{url} is not a url"
      rescue PublicAddress::Blocked => e
        raise Resource::Unusable, "#{key}: #{e.message}"
      rescue PublicAddress::Unresolvable => e
        raise Resource::Failed, "#{key}: #{e.message}"
      end

      def git(*args, env: {}, binary: false, bare: false)
        command = [ "git" ]
        command += [ "-C", working_dir ] unless bare
        command += %w[-c protocol.file.allow=never -c core.askPass= -c credential.helper=
                      -c http.followRedirects=false]
        command += args.map(&:to_s)

        run(environment(env), command, binary: binary)
      end

      def environment(extra)
        {
          "GIT_TERMINAL_PROMPT" => "0",
          "GIT_ALLOW_PROTOCOL" => self.class.protocols.join(":"),
          "GIT_CONFIG_GLOBAL" => File::NULL,
          "GIT_CONFIG_SYSTEM" => File::NULL,
          "GIT_ASKPASS" => "",
          "LC_ALL" => "C"
        }.merge(extra)
      end

      def resolving(pinned)
        return [] if pinned.nil?

        address = pinned.address.include?(":") ? "[#{pinned.address}]" : pinned.address

        [ "-c", "http.curloptResolve=#{pinned.uri.hostname}:#{pinned.uri.port}:#{address}" ]
      end

      def run(env, command, binary:)
        stdout, stderr, status = capture(env, command, binary)

        return stdout if status.success?

        raise Resource::Failed, "#{key}: git #{command[-2]} — #{scrubbed(stderr)}"
      rescue Errno::ENOENT
        raise Resource::Unusable, "#{key}: git is not installed where the worker runs"
      end

      def capture(env, command, binary)
        Open3.popen3(env, *command, pgroup: true) do |stdin, stdout, stderr, waiter|
          stdin.close
          stdout.binmode if binary
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }

          unless waiter.join(TIMEOUT)
            Process.kill("KILL", -waiter.pid)
            [ out, err ].each(&:kill)
            raise Resource::Failed, "#{key}: git #{command[-2]} ran past #{TIMEOUT}s and was stopped"
          end

          [ out.value, err.value, waiter.value ]
        end
      end

      def scrubbed(said)
        held = said.to_s.squish.truncate(300)
        token = credentials["token"].presence

        token ? held.gsub(token, "…") : held
      end

      def it_names_a_repository
        return errors.add(:details, "must name a url") if url.blank?

        permitted!
      rescue Resource::Failed => e
        errors.add(:details, e.message.split(": ", 2).last)
      end
  end
end
