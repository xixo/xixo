require "test_helper"
require_relative "../../support/machines"

module ScriptedMachine
  class << self
    attr_accessor :script

    def staged = (@staged ||= [])

    def forgotten = (@forgotten ||= [])
  end

  def ask(verb, args = {}, within: nil)
    return super(verb, args, **{ within: within }.compact) if ScriptedMachine.script.nil?

    ScriptedMachine.script.call(verb.to_s, args.to_h.deep_stringify_keys)
  end

  def upload(io)
    return super if ScriptedMachine.script.nil?

    body = io.read.to_s.b
    ScriptedMachine.staged << body
    { "upload" => SecureRandom.uuid, "size" => body.bytesize }
  end

  def forget(request)
    return super if ScriptedMachine.script.nil?

    ScriptedMachine.forgotten << request
  end
end

Resource::XixoAgent.prepend(ScriptedMachine)

class MachineToolsTest < ActiveSupport::TestCase
  include Machines

  ALL = %w[browse search read write extract models].freeze

  setup do
    @tenant = Tenant.create!(subdomain: "tools-#{SecureRandom.hex(4)}", name: "Tools")
    @machine = agent_on(@tenant, folders: [ "/srv/media", "/srv/notes", "/srv/photos" ])
    @asked = []
    ScriptedMachine.script = lambda do |verb, args|
      @asked << [ verb, args ]
      @answers.fetch(verb) { raise "asked #{verb}" }.then { |held| held.respond_to?(:call) ? held.call(args) : held }
    end
    @answers = {}
  end

  teardown do
    ScriptedMachine.script = nil
    ScriptedMachine.staged.clear
    ScriptedMachine.forgotten.clear
    Current.reset
  end

  test "hello keeps the tools the machine names that xixo knows, and whether it lends" do
    said = Resource::XixoAgent::Hello.from("folders" => [ "/srv" ], "tools" => [ "read", "shell", 5, "browse", "read" ], "lend" => true)

    assert_equal %w[browse read], said["tools"]
    assert said["lend"]
    assert_equal [], Resource::XixoAgent::Hello.from("tools" => "browse")["tools"]
    assert_not Resource::XixoAgent::Hello.from("lend" => "yes")["lend"]
  end

  test "a machine whose config names no tools offers health alone, and refuses the rest" do
    as_member do
      described = JSON.parse(text(called(key: "box", do: "describe")))

      assert_equal %w[health discover], described["commands"].keys
      assert_equal %w[health discover], described["help"].keys

      ALL.map { |tool| tool == "models" ? "chat" : tool }.each do |verb|
        reply = called(key: "box", do: verb, input: { folder: "/srv/media", path: "a.txt", query: "a", prompt: "hi", text: "x" })

        assert reply.error?, verb
        assert_match(/box does not offer #{verb}/, text(reply))
      end

      assert_empty @asked
      assert_equal "error", AuditEvent.where(channel: "mcp").order(:id).last.status
    end
  end

  test "a machine offers write only with a writable folder, and chat only with a model server" do
    offering(ALL)

    Tenant.switch(@tenant) do
      assert_equal %w[health discover browse search read extract], @machine.reload.commands.keys.map(&:to_s)

      offering(ALL, writable: [ "/srv/notes" ], services: [ { "kind" => "ollama", "port" => 11_434 } ])
      assert_equal %w[health discover browse search read write extract chat], @machine.reload.commands.keys.map(&:to_s)
    end
  end

  test "browse lists the shared folders, then the files of one, and refuses a folder the machine does not share" do
    offering(%w[browse], writable: [ "/srv/notes" ])
    @answers["browse"] = { "entries" => [ { "path" => "a.txt", "size" => 3, "modified_at" => "2026-10-12T10:00:00Z" } ], "cursor" => "a.txt" }

    as_member do
      folders = JSON.parse(text(called(key: "box", do: "browse")))["folders"]
      assert_equal [ { "folder" => "/srv/media", "writable" => false }, { "folder" => "/srv/notes", "writable" => true },
                     { "folder" => "/srv/photos", "writable" => false } ], folders

      listed = JSON.parse(text(called(key: "box", do: "browse", input: { folder: "/srv/media", limit: 5000 })))
      assert_equal [ "a.txt" ], listed["files"].map { |file| file["path"] }
      assert_equal "a.txt", listed["cursor"]
      assert_equal [ "browse", { "folder" => "/srv/media", "limit" => 200 } ], @asked.last

      refused = called(key: "box", do: "browse", input: { folder: "/etc" })
      assert refused.error?
      assert_match(/box shares no folder \/etc/, text(refused))
      assert_equal 1, @asked.size
    end
  end

  test "a folder attached for one person is out of reach of everyone else's token" do
    offering(%w[browse read])
    Tenant.switch(@tenant) do
      Resource::Filesystem.create!(key: "bobs", details: { "folder" => "/srv/photos" }, via: @machine, owner_subject: "bob")
    end

    as_member do
      folders = JSON.parse(text(called(key: "box", do: "browse")))["folders"].map { |held| held["folder"] }
      assert_equal %w[/srv/media /srv/notes], folders

      reply = called(key: "box", do: "read", input: { folder: "/srv/photos", path: "a.jpg" })
      assert reply.error?
      assert_match(/holds what is kept for one person/, text(reply))
      assert_empty @asked
    end
  end

  test "a shared folder that holds a file kept to one person is out of reach of everyone else's token" do
    offering(%w[browse])
    Tenant.switch(@tenant) do
      storage = Resource::Filesystem.create!(key: "storage", details: { "folder" => "/srv/notes" }, via: @machine)
      kept = Feed.create!(type: Feed::FILE, key: "diary", title: "Diary")
      Reference.create!(feed: kept, resource: storage, locator_key: "diary.txt", locator: { "path" => "diary.txt" })
      kept.update_columns(readers: [ "bob" ])
    end
    @answers["browse"] = { "entries" => [] }

    as_member do
      assert_equal %w[/srv/media /srv/photos], JSON.parse(text(called(key: "box", do: "browse")))["folders"].map { |held| held["folder"] }
      assert_match(/holds what is kept for one person/, text(called(key: "box", do: "browse", input: { folder: "/srv/notes" })))
    end

    Tenant.switch(@tenant) do
      Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "bob", "scope" => Grant::SIGN_IN.join(" ")))
      assert_not called(key: "box", do: "browse", input: { folder: "/srv/notes" }).error?
    end
  end

  test "read sends the head of a file from a machine that lends, and what xixo drew out from one that does not" do
    offering(%w[read], lend: true)
    @answers["peek"] = { "data" => Base64.strict_encode64("# plans\nfirst"), "size" => 13, "total" => 900_000 }

    as_member do
      read = JSON.parse(text(called(key: "box", do: "read", input: { folder: "/srv/notes", path: "plans.md" })))
      assert_equal "# plans\nfirst", read["text"]
      assert read["truncated"]
      assert_equal [ "peek", { "folder" => "/srv/notes", "path" => "plans.md", "limit" => 256.kilobytes } ], @asked.last

      [ "../etc/passwd", "/etc/passwd", "a//b" ].each do |path|
        assert called(key: "box", do: "read", input: { folder: "/srv/notes", path: path }).error?, path
      end
    end

    offering(%w[read], lend: false)
    Tenant.switch(@tenant) do
      folder = Resource::Filesystem.create!(key: "notes", details: { "folder" => "/srv/notes" }, via: @machine)
      feed = Feed.create!(type: Feed::FILE, key: "plans", title: "Plans")
      Analysis.create!(feed: feed, cause: "manual", status: "done", finished_at: Time.current,
                       steps: { "text" => { "result" => "the plans, as extracted", "finished_at" => Time.current.iso8601 } })
      Reference.create!(feed: feed, resource: folder, locator_key: "plans.md", locator: { "path" => "plans.md" })
    end

    as_member do
      @asked.clear
      read = JSON.parse(text(called(key: "box", do: "read", input: { folder: "/srv/notes", path: "plans.md" })))

      assert_equal "the plans, as extracted", read["text"]
      assert_match(/does not lend its files' bytes, so they stay on it/, read["note"])
      assert_empty @asked
    end
  end

  test "write needs the command scope and a writable folder, and carries the bytes as an upload" do
    offering(%w[write], writable: [ "/srv/notes" ])
    @answers["place"] = ->(args) { { "path" => args["path"], "size" => args["size"], "modified_at" => "2026-10-12T10:00:00Z" } }

    as_member(Grant::SIGN_IN - [ Tool::Resources::WRITES ]) do
      assert_not_includes Tool::Resources.for(Current.grant).input_schema.to_h.dig(:properties, :do, :enum), "write"

      reply = called(key: "box", do: "write", input: { folder: "/srv/notes", path: "x.md", text: "hi" })
      assert_match(/does not carry xixo:resources:command/, text(reply))
    end

    as_member do
      written = JSON.parse(text(called(key: "box", do: "write", input: { folder: "/srv/notes", path: "new/x.md", text: "hello" })))
      assert_equal 5, written["size"]
      verb, args = @asked.last
      assert_equal "place", verb
      assert_equal [ "/srv/notes", "new/x.md", false, 5 ], args.values_at("folder", "path", "replace", "size")
      assert AgentExchange.uuid?(args["upload"])
      assert_equal [ "hello" ], ScriptedMachine.staged
      assert_equal [ args["upload"] ], ScriptedMachine.forgotten

      read_only = called(key: "box", do: "write", input: { folder: "/srv/media", path: "x.md", text: "hi" })
      assert_match(/shares \/srv\/media read-only/, text(read_only))

      big = called(key: "box", do: "write", input: { folder: "/srv/notes", path: "x.bin", base64: Base64.strict_encode64("x" * (1.megabyte + 1)) })
      assert_match(/at most 1048576 bytes/, text(big))

      both = called(key: "box", do: "write", input: { folder: "/srv/notes", path: "x.md", text: "a", base64: "YQ==" })
      assert_match(/text or base64, and not both/, text(both))
      assert_equal 1, @asked.size
    end
  end

  test "extract runs the machine's extractors and answers with capped steps" do
    offering(%w[extract])
    @answers["examine"] = { "extractor" => "pdf", "size" => 10, "sha256" => "ab",
                            "steps" => { "text" => { "result" => "y" * 100_000 }, "pages" => { "result" => { "count" => 3 } },
                                         "ocr" => { "error" => "tesseract is missing" } } }

    as_member do
      held = JSON.parse(text(called(key: "box", do: "extract", input: { folder: "/srv/media", path: "doc.pdf" })))

      assert_equal 64.kilobytes, held.dig("steps", "text", "result").size
      assert_equal 3, held.dig("steps", "pages", "result", "count")
      assert_equal "tesseract is missing", held.dig("steps", "ocr", "error")
      verb, args = @asked.last
      assert_equal "examine", verb
      assert_equal({ "folder" => "/srv/media", "path" => "doc.pdf" }, args["source"])
      assert_equal "application/pdf", args["mime"]
    end
  end

  test "chat asks the model server the machine found, and only one it found" do
    offering(%w[models], services: [ { "kind" => "ollama", "port" => 11_434, "address" => nil } ])
    @answers["model"] = { "model" => "qwen3:8b", "text" => "four", "finish_reason" => "stop" }

    as_member do
      answered = JSON.parse(text(called(key: "box", do: "chat", input: { prompt: "two and two?", system: "Be brief." })))
      assert_equal({ "kind" => "ollama", "model" => "qwen3:8b", "text" => "four", "finish_reason" => "stop" }, answered)

      verb, args = @asked.last
      assert_equal "model", verb
      assert_equal({ "kind" => "ollama", "messages" => [ { "role" => "system", "content" => "Be brief." },
                                                         { "role" => "user", "content" => "two and two?" } ] }, args)

      other = called(key: "box", do: "chat", input: { prompt: "hi", kind: "lmstudio" })
      assert_match(/box runs ollama, and no lmstudio/, text(other))

      long = called(key: "box", do: "chat", input: { prompt: "x" * (64.kilobytes + 1) })
      assert_match(/at most 65536 bytes/, text(long))
      assert_equal 1, @asked.size
    end
  end

  test "search answers from xixo's index of the machine's folders and from a walk of their names" do
    offering(%w[search])
    feed = nil
    Tenant.switch(@tenant) do
      folder = Resource::Filesystem.create!(key: "notes", details: { "folder" => "/srv/notes" }, via: @machine)
      feed = Feed.create!(type: Feed::FILE, key: "plans", title: "Plans")
      Reference.create!(feed: feed, resource: folder, locator_key: "plans.md", locator: { "path" => "plans.md" })
      @elsewhere = Feed.create!(type: Feed::NOTE, key: "elsewhere", title: "Plans elsewhere")
    end
    @answers["find"] = { "matches" => [ { "folder" => "/srv/media", "path" => "plans.mp4", "size" => 9 },
                                        { "folder" => "/etc", "path" => "plans" } ], "visited" => 20_000, "complete" => false }

    as_member do
      original = SearchIndex.method(:search)
      found = [ @elsewhere.id, feed.id ]
      SearchIndex.define_singleton_method(:search) { |*, **| found }

      begin
        held = JSON.parse(text(called(key: "box", do: "search", input: { query: "plans" })))

        assert_equal [ [ "/srv/notes", "plans.md" ] ], held["indexed"].map { |found| found.values_at("folder", "path") }
        assert_equal [ [ "/srv/media", "plans.mp4" ] ], held["named"].map { |found| found.values_at("folder", "path") }
        assert_match(/stopped before it reached every file/, held["note"])
        assert_equal [ "find", { "query" => "plans", "limit" => 100 } ], @asked.last
      ensure
        SearchIndex.define_singleton_method(:search, original)
      end
    end
  end

  private

    def offering(tools, writable: [], services: [], lend: false)
      Tenant.switch(@tenant) do
        @machine.reload.update!(details: @machine.details.merge("machine" => @machine.machine.merge(
          "tools" => tools, "writable" => writable, "services" => services, "lend" => lend
        )))
      end
    end

    def as_member(scopes = Grant::SIGN_IN)
      Tenant.switch(@tenant) do
        Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "alice", "scope" => scopes.join(" ")))
        yield
      end
    end

    def called(**arguments)
      Tool::Resources.call(server_context: {}, **arguments)
    end

    def text(reply)
      reply.content.first[:text]
    end
end
