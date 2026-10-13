module Tool
  class Move < Base
    tool_name "move"
    scope "xixo:resources:command"

    description <<~TEXT
      Move files from a folder on one machine running xixo link into a folder on another. Each file is
      copied, both machines hash their copy, and the original is deleted only when the hashes match. A
      file whose copy does not match, or whose new path already holds other bytes, stays where it is.
      Name the files with from, a folder resource's key, and an optional path inside it, or with ids,
      query, or type. to is the key of the folder resource they go to, and into a folder inside it.
      The move runs in the background: the answer is its run, and calling move again with run checks on
      it, or with run and stop true stops it. A folder its machine shares read-only refuses the move, and
      the error names the folder to share writable on that machine, which only a person there can do.
      Only an operator of both machines moves files.
    TEXT

    input_schema(
      properties: {
        from: { type: "string", description: "The key of the folder resource the files leave." },
        path: {
          type: "string",
          description: "A folder or a file inside from, such as Photos/2019. Left off, everything in from moves."
        },
        ids: { type: "array", items: { type: "string" }, description: "The ids of the files to move, without from." },
        query: { type: "string", description: "Moves the files a search finds, without from." },
        type: { type: "string", description: "Moves the files of one type, such as xixo:file, without from." },
        to: { type: "string", description: "The key of the folder resource the files go to." },
        into: { type: "string", description: "A folder inside to. Left off, the files land at its top." },
        run: { type: "string", description: "The id of a move already started, to see how far it has come." },
        stop: { type: "boolean", description: "With run, stops the move after the files it is moving." }
      }
    )

    def self.call(server_context:, from: nil, path: nil, ids: nil, query: nil, type: nil, to: nil, into: nil,
                  run: nil, stop: false)
      arguments = { from: from, path: path, ids: ids, query: query, type: type, to: to, into: into, run: run,
                    stop: stop }.compact

      respond(server_context, arguments) do
        next followed(run, stop: stop == true) if run.present?

        raise ArgumentError, "move needs to, the key of the folder the files go to" if to.blank?

        within_budget!
        feeds = { "id" => Array(ids).presence, "query" => query.presence, "type" => type.presence }.compact
        started = ::Move.start!(grant: Current.grant, destination: place!(to), into: into,
                                source: (place!(from) if from.present?), path: path, feeds: feeds.presence)

        told(started)
      end
    end

    def self.followed(id, stop:)
      held = ::Run.visible_to(Current.grant).find_by(id: id, kind: "move") || raise(ArgumentError, "no move with run #{id}")
      held.cancel! if stop

      told(held.reload)
    end

    def self.place!(key)
      ::Resource.visible_to(Current.grant).find_by(key: key) || raise(ArgumentError, "no resource called #{key}")
    end

    def self.told(run)
      {
        run: run.id.to_s, status: run.status, error: run.error, started_at: run.started_at,
        finished_at: run.finished_at, moved: ::Move.progress(run.id).to_h,
        stayed: run.logs.to_s.lines.grep(/\A\[x\]/).last(20).map { |line| line.delete_prefix("[x] : ").strip }
      }
    end

    def self.saying(arguments)
      return "stopped a move" if arguments[:run].present? && arguments[:stop]
      return "checked on a move" if arguments[:run].present?

      what = arguments[:from].present? ? [ arguments[:from], arguments[:path] ].compact_blank.join(": ") : "a selection of files"
      "moved #{what} to #{[ arguments[:to], arguments[:into] ].compact_blank.join(': ')}"
    end
  end
end
