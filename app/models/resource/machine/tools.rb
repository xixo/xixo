class Resource
  class Machine
    module Tools
      extend ActiveSupport::Concern

      NAMES = %w[browse search read write extract models].freeze

      OFFERED_AS = {
        browse: "browse", search: "search", read: "read", write: "write", extract: "extract", chat: "models"
      }.freeze

      SCHEMA = {
        browse: { folder: "string?", prefix: "string?", cursor: "string?", limit: "integer?" },
        search: { query: "string", folder: "string?", limit: "integer?" },
        read: { folder: "string", path: "string" },
        write: { folder: "string", path: "string", text: "string?", base64: "string?", replace: "boolean?" },
        extract: { folder: "string", path: "string" },
        chat: { prompt: "string", system: "string?", model: "string?", kind: "string?", max_tokens: "integer?" }
      }.freeze

      HELP = {
        health: "Reads the machine's uptime, load, memory, and disks from xixo link on it.",
        discover: "Lists the folders the machine shares, each with the type and address to attach it as a folder.",
        browse: "Lists the files in a folder the machine shares, depth first in name order, at most 200 at a time. " \
                "Left without a folder, it lists the shared folders. A cursor in the answer is passed back to " \
                "read on. Needs the machine to offer browse, and a token for one of its operators.",
        search: "Finds files on the machine for a query, at most 100 of each kind. It searches xixo's index of " \
                "the machine's folders, which matches titles, paths, and text drawn out by analysis, and walks " \
                "the folders on the machine for paths that hold the query, ignoring case, stopping after 20,000 " \
                "files or ten seconds. Only a token for one of its operators walks the folders. Needs the machine to " \
                "offer search.",
        read: "Reads up to 256 KiB of a shared file as text. When the machine does not lend its files' bytes, or " \
              "is offline, or the token is not one of its operators', it answers with what xixo drew out of the " \
              "file instead, and says so. Needs the machine to offer read.",
        write: "Writes a file of at most 1 MiB, given as text or base64, into a folder the machine marks writable. " \
               "Without replace true it refuses to overwrite a file. Needs xixo:resources:command, a token for one " \
               "of its operators, and the machine to offer write.",
        extract: "Runs the machine's own extractors on a shared file and answers with the text and metadata they " \
                 "draw out, without keeping anything. Needs the machine to offer extract, and a token for one of " \
                 "its operators.",
        chat: "Asks a model server running on the machine, such as Ollama or LM Studio, one question and answers " \
              "with its reply, at most 64 KiB. kind picks the server when the machine runs more than one, and " \
              "model picks the model, the server's first when left off. Needs the machine to offer models, and a " \
              "token for one of its operators."
      }.freeze

      HELD_BACK = {
        browse: "browse its folders", write: "write into its folders", extract: "run its extractors",
        chat: "ask the model server on it"
      }.freeze
      OPERATED = HELD_BACK.keys.freeze

      MOST_READ = 256.kilobytes
      MOST_WRITTEN = 1.megabyte
      MOST_EXTRACTED = 64.kilobytes
      MOST_BROWSED = 200
      MOST_FOUND = 100
      MOST_PROMPT = 64.kilobytes
      MOST_TOKENS = 4096
      INDEXED_FIRST = 200
      FOUND_WITHIN = 20.seconds
      EXTRACTED_WITHIN = 120.seconds
      ANSWERED_WITHIN_MODEL = 90.seconds
      WRITTEN_WITHIN = 60.seconds
      STAYS = "the machine does not lend its files' bytes, so they stay on it; this is what xixo drew out of the file".freeze
      UNLISTED = "this token speaks for someone the machine does not list among its operators, so its files' bytes " \
                 "stay on it; this is what xixo drew out of the file".freeze
      AWAY = "the machine is not connected, so this is what xixo drew out of the file".freeze

      class_methods do
        def tools_schema = SCHEMA

        def tools_help = HELP
      end

      def offered_tools
        NAMES & Array(machine["tools"])
      end

      def offers?(tool)
        offered_tools.include?(tool.to_s)
      end

      def model_kinds
        Array(machine["services"]).filter_map { |service| service["kind"] if service.is_a?(Hash) }.uniq
      end

      def commands
        self.class.command_schema.select { |name, _| offered_command?(name) }
      end

      def operators
        Array(details.to_h["operators"]).grep(String).compact_blank
      end

      def operated_by?(grant)
        return false if grant.nil?

        grant.administers? || (grant.speaks_for.present? && operators.include?(grant.speaks_for))
      end

      def operated_by!(grant)
        return if grant.nil? || !grant.administers? || grant.speaks_for.blank? || operators.include?(grant.speaks_for)

        self.details = details.to_h.merge("operators" => operators + [ grant.speaks_for ])
      end

      def command(name, arguments = {})
        tool = OFFERED_AS[name.to_s.to_sym]

        if OPERATED.include?(name.to_s.to_sym) && !operated_by?(Current.grant)
          raise Resource::Refused, "#{key} lets only its operators #{HELD_BACK.fetch(name.to_s.to_sym)}. An " \
                                   "administrator lists who operates it on the Resources page"
        end

        if tool && !offered_command?(name.to_s.to_sym)
          raise ArgumentError, "#{key} does not offer #{name}: #{unoffered(tool)}"
        end

        super
      end

      def command_browse(folder: nil, prefix: nil, cursor: nil, limit: nil)
        return { "folders" => shared_folders } if folder.blank?

        root = reachable_folder!(folder)
        asked = { "folder" => root, "prefix" => text!(prefix, "prefix").presence, "cursor" => text!(cursor, "cursor").presence,
                  "limit" => count!(limit, MOST_BROWSED) }.compact
        held = ask("browse", asked).to_h

        { "folder" => root, "files" => Array(held["entries"]).first(MOST_BROWSED).filter_map { |entry| file_told(entry) },
          "cursor" => held["cursor"].presence }.compact
      end

      def command_search(query:, folder: nil, limit: nil)
        wanted = text!(query, "query").strip
        raise ArgumentError, "search takes a query of 1 to 200 characters" unless wanted.length.between?(1, 200)

        roots = folder.present? ? [ reachable_folder!(folder) ] : shared_folders.map { |held| held["folder"] }
        most = count!(limit, MOST_FOUND)
        indexed = indexed(wanted, roots, most)
        named, note = walked(wanted, folder.present? ? roots.first : nil, most, roots)

        { "indexed" => indexed, "named" => named, "note" => note }.compact
      end

      def command_read(folder:, path:)
        root = reachable_folder!(folder)
        relative = relative!(path)

        return drawn_out(root, relative, AWAY) unless connected?
        return drawn_out(root, relative, STAYS) unless lends?
        return drawn_out(root, relative, UNLISTED) unless operated_by?(Current.grant)

        held = ask("peek", { "folder" => root, "path" => relative, "limit" => MOST_READ }).to_h
        bytes = Base64.strict_decode64(held["data"].to_s)
        read_told(root, relative, bytes, held["total"])
      rescue ArgumentError => e
        raise e unless e.message.include?("invalid base64")

        raise Resource::Failed, "#{key}: xixo link answered peek with something that is not base64"
      end

      def command_write(folder:, path:, text: nil, base64: nil, replace: nil)
        Current.grant&.permit!(::Tool::Resources::WRITES)
        root = reachable_folder!(folder)
        relative = relative!(path)
        raise Resource::Refused, "#{key} shares #{root} read-only: its config does not mark it writable" unless writable_folders.include?(root)

        body = written_body(text, base64)
        staged = upload(StringIO.new(body))

        begin
          written = long(WRITTEN_WITHIN) do
            ask("place", staged.merge("folder" => root, "path" => relative, "replace" => replace == true), within: WRITTEN_WITHIN)
          end
        ensure
          forget(staged["upload"])
        end

        { "folder" => root, "path" => relative, "size" => written.to_h["size"], "modified_at" => written.to_h["modified_at"] }
      end

      def command_extract(folder:, path:)
        root = reachable_folder!(folder)
        relative = relative!(path)

        asked = { "source" => { "folder" => root, "path" => relative }, "filename" => File.basename(relative),
                  "mime" => MimeType.for_filename(relative).to_s }
        held = long(EXTRACTED_WITHIN) { ask("examine", asked, within: EXTRACTED_WITHIN) }.to_h

        { "folder" => root, "path" => relative, "extractor" => held["extractor"].to_s.first(40).presence,
          "size" => held["size"], "sha256" => held["sha256"], "steps" => steps_told(held["steps"]),
          "dropped" => held["dropped"].presence }.compact
      end

      def command_chat(prompt:, system: nil, model: nil, kind: nil, max_tokens: nil)
        asked = text!(prompt, "prompt")
        told = text!(system, "system")
        raise ArgumentError, "chat takes a prompt" if asked.blank?
        raise ArgumentError, "a prompt and its system message hold at most #{MOST_PROMPT} bytes" if asked.bytesize + told.bytesize > MOST_PROMPT

        server = model_server!(kind)
        messages = [ ({ "role" => "system", "content" => told } if told.present?), { "role" => "user", "content" => asked } ].compact
        wanted = { "kind" => server, "model" => text!(model, "model").first(200).presence, "messages" => messages,
                   "max_tokens" => (count!(max_tokens, MOST_TOKENS) unless max_tokens.nil?) }.compact
        held = long(ANSWERED_WITHIN_MODEL) { ask("model", wanted, within: ANSWERED_WITHIN_MODEL) }.to_h

        { "kind" => server, "model" => held["model"].to_s.first(200), "text" => held["text"].to_s.scrub.first(MOST_PROMPT),
          "truncated" => (true if held["truncated"] == true), "finish_reason" => held["finish_reason"].presence }.compact
      end

      private

        def long(within, &)
          Busy.hold(self, Current.grant, within: within, &)
        end

        def offered_command?(name)
          tool = OFFERED_AS[name.to_sym]
          return true if tool.nil?
          return false if OPERATED.include?(name.to_sym) && !operated_by?(Current.grant)
          return false unless offers?(tool)
          return writable_folders.any? if name.to_sym == :write
          return model_kinds.any? if name.to_sym == :chat

          true
        end

        def unoffered(tool)
          return "its config leaves #{tool} out of tools" unless offers?(tool)
          return "it shares no folder writable" if tool == "write"

          "no model server answered on it"
        end

        def shared_folders
          offered_folders.reject { |folder| withheld?(folder) }.map do |folder|
            { "folder" => folder, "writable" => writable_folders.include?(folder) }
          end
        end

        def reachable_folder!(folder)
          held = text!(folder, "folder")
          raise ArgumentError, "#{key} shares no folder #{held.first(200)}. It shares #{offered_folders.to_sentence}" unless offered_folders.include?(held)
          if withheld?(held)
            raise Resource::Refused, "#{held} on #{key} holds what is kept for one person, and this token speaks for someone else"
          end

          held
        end

        def withheld?(folder)
          speaking = Current.grant&.speaks_for
          overlapping = Filesystem.where(via_id: id).select { |held| overlapping?(held.folder, folder) }
          return true if overlapping.any? { |held| held.owner_subject.present? && held.owner_subject != speaking }

          Reference.where(resource_id: overlapping.map(&:id))
                   .where.not(feed_id: Feed.readable_to(speaking).select(:id))
                   .exists?
        end

        def overlapping?(one, other)
          a, b = [ one, other ].map { |path| path.to_s.delete_suffix("/").presence || "/" }

          a == b || [ [ a, b ], [ b, a ] ].any? { |outer, inner| outer == "/" || inner.start_with?("#{outer}/") }
        end

        def relative!(path)
          held = text!(path, "path")
          parts = held.split("/")

          if held.empty? || held.bytesize > MOST_PATH || held.start_with?("/") || held.include?("\0") ||
             parts.any? { |part| part.empty? || part.in?(%w[. ..]) }
            raise ArgumentError, "#{held.first(80).inspect} is not a path inside the folder"
          end

          held
        end

        def text!(value, named)
          return "" if value.nil?
          raise ArgumentError, "#{named} is a string" unless value.is_a?(String)
          raise ArgumentError, "#{named} is not valid UTF-8" unless value.valid_encoding?

          value
        end

        def count!(value, most)
          return most if value.nil?
          raise ArgumentError, "limit is a whole number" unless value.is_a?(Integer)

          value.clamp(1, most)
        end

        def file_told(entry)
          return nil unless entry.is_a?(Hash) && entry["path"].is_a?(String)

          { "path" => entry["path"].scrub.first(MOST_PATH), "size" => entry["size"], "modified_at" => entry["modified_at"] }.compact
        end

        def indexed(query, roots, most)
          folders = Filesystem.where(via_id: id).select { |held| roots.include?(held.folder) }
          return [] if folders.empty?

          ids = SearchIndex.search(query, limit: INDEXED_FIRST)
          return [] if ids.empty?

          references = Reference.originals.where(resource_id: folders.map(&:id), gone_at: nil)
          feeds = Feed.readable_by(Current.grant).where(id: ids).where(id: references.select(:feed_id))
                      .includes(:references).in_order_of(:id, ids).limit(most).to_a
          Current.grant&.read_privately!(feeds)

          by_id = folders.index_by(&:id)
          feeds.filter_map do |feed|
            reference = feed.references.find { |held| by_id.key?(held.resource_id) && held.gone_at.nil? }
            next if reference.nil?

            { "feed_id" => feed.id.to_s, "title" => feed.title, "folder" => by_id[reference.resource_id].folder,
              "path" => reference.locator_key, "mime" => reference.mime,
              "gist" => (feed.summary || feed.readable_text)&.squish&.truncate(300) }.compact
          end
        end

        def walked(query, folder, most, roots)
          return [ [], "the machine does not offer search to walk its folders' names, so only xixo's index was searched" ] unless offers?("search")
          return [ [], "the machine is not connected, so only xixo's index was searched" ] unless connected?
          return [ [], "this token speaks for someone the machine does not list among its operators, so only xixo's index was searched" ] unless operated_by?(Current.grant)

          held = long(FOUND_WITHIN) { ask("find", { "query" => query, "folder" => folder, "limit" => most }.compact, within: FOUND_WITHIN) }.to_h
          found = Array(held["matches"]).filter_map do |match|
            next unless match.is_a?(Hash) && roots.include?(match["folder"])

            { "folder" => match["folder"], "path" => match["path"].to_s.scrub.first(MOST_PATH), "size" => match["size"],
              "modified_at" => match["modified_at"] }.compact
          end.first(most)

          [ found, ("the walk stopped before it reached every file" unless held["complete"] == true) ]
        end

        def read_told(root, relative, bytes, total)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          cuts = (0..3).map { |cut| text.byteslice(0, text.bytesize - cut) }
          readable = cuts.find(&:valid_encoding?)
          size = total.is_a?(Integer) ? total : bytes.bytesize
          told = { "folder" => root, "path" => relative, "size" => size }

          if readable.nil? || readable.count("\x00") > 0
            return told.merge("text" => nil, "note" => "the file is not text; extract reads what is inside it")
          end

          told.merge("text" => readable, "truncated" => (true if size > bytes.bytesize)).compact
        end

        def drawn_out(root, relative, note)
          folders = Filesystem.where(via_id: id).select { |held| held.folder == root }
          reference = Reference.originals.where(resource_id: folders.map(&:id), locator_key: relative, gone_at: nil).first
          feed = reference && Feed.readable_by(Current.grant).find_by(id: reference.feed_id)

          if feed.nil?
            return { "folder" => root, "path" => relative, "text" => nil,
                     "note" => "#{note.split(';').first}, and xixo has not drawn anything out of #{relative}" }
          end

          Current.grant&.read_privately!(feed)
          { "folder" => root, "path" => relative, "feed_id" => feed.id.to_s, "title" => feed.title,
            "summary" => feed.summary, "text" => feed.readable_text&.first(MOST_READ), "note" => note }.compact
        end

        def written_body(text, base64)
          raise ArgumentError, "write takes text or base64, and not both" if text.nil? == base64.nil?

          body = if text
            text!(text, "text").b
          else
            Base64.strict_decode64(text!(base64, "base64"))
          end
          raise ArgumentError, "a file written through a tool holds at most #{MOST_WRITTEN} bytes" if body.bytesize > MOST_WRITTEN

          body
        rescue ArgumentError => e
          raise e unless e.message.include?("invalid base64")

          raise ArgumentError, "base64 is not valid base64"
        end

        def steps_told(steps)
          return {} unless steps.is_a?(Hash)

          steps.first(32).to_h do |name, step|
            held = step.is_a?(Hash) ? step : {}
            result = held["result"]
            result = result.scrub.first(MOST_EXTRACTED) if result.is_a?(String)
            result = nil if !result.is_a?(String) && result.to_json.bytesize > MOST_EXTRACTED

            [ name.to_s.first(40), { "result" => result, "error" => held["error"].to_s.first(500).presence }.compact ]
          end
        end

        def model_server!(kind)
          kinds = model_kinds
          wanted = text!(kind, "kind").presence
          raise ArgumentError, "#{key} runs no model server xixo knows of" if kinds.empty?
          return kinds.first if wanted.nil?
          raise ArgumentError, "#{key} runs #{kinds.to_sentence}, and no #{wanted.first(40)}" unless kinds.include?(wanted)

          wanted
        end
    end
  end
end
