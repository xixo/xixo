class FakeLinks
  Held = Struct.new(:bytes, :modified_at)

  module Overheard
    mattr_accessor :listener

    def broadcast_to(model, message)
      listener = Overheard.listener
      return listener.heard(model, message) if listener && message.is_a?(Hash) && message["request"]

      super
    end
  end

  LinkChannel.singleton_class.prepend(Overheard)

  attr_reader :asked
  attr_accessor :corrupting, :removing

  def initialize(tenant, folders)
    @tenant = tenant
    @folders = folders
    @asked = Queue.new
    @inbox = Queue.new
    @writers = []
  end

  def start
    Overheard.listener = self
    @thread = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { Tenant.switch(@tenant) { answering } }
    end
    self
  end

  def stop
    Overheard.listener = nil
    @inbox << :stop
    @thread&.join(10)
    @writers.each { |writer| writer.join(10) }
  end

  def heard(machine, message)
    @asked << [ machine.key, message["verb"], message["args"] ]
    @inbox << [ machine.id, message ]
  end

  def add(machine_id, folder, files)
    (@folders[machine_id] ||= {})[folder] = files
  end

  def files(machine, folder)
    @folders.fetch(machine.id).fetch(folder)
  end

  def verbs
    held = []
    held << @asked.pop until @asked.empty?
    held.each { |entry| @asked << entry }
    held
  end

  private

    def answering
      loop do
        item = @inbox.pop
        break if item == :stop

        machine_id, message = item
        exchange = LinkExchange.find_by(resource_id: machine_id, request: message["request"])
        next if exchange.nil?

        if message["verb"] == "write"
          @writers << writer(machine_id, exchange, message["args"])
        else
          answered(machine_id, exchange, message["verb"], message["args"])
        end
      end
    end

    def answered(machine_id, exchange, verb, args)
      folder = @folders.dig(machine_id, args["folder"])
      return exchange.refuse!("this folder is not shared") if folder.nil?

      case verb
      when "list" then exchange.answer!("entries" => listed(folder, args))
      when "hash" then hashed(exchange, folder, args)
      when "read" then sent(exchange, folder, args)
      when "remove" then removed(exchange, folder, args)
      else exchange.refuse!("xixo link does not know the verb #{verb.inspect}")
      end
    end

    def listed(folder, args)
      prefix = args["prefix"].to_s
      after = args["cursor"].to_s

      folder.keys.sort.select { |path| path.start_with?(prefix) && path > after }.first(args["limit"] || 500).map do |path|
        { "path" => path, "size" => folder[path].bytes.bytesize, "modified_at" => folder[path].modified_at.utc.iso8601(9) }
      end
    end

    def hashed(exchange, folder, args)
      held = folder[args["path"]]
      return exchange.refuse!("no such file") if held.nil?

      exchange.answer!("sha256" => Digest::SHA256.hexdigest(held.bytes), "size" => held.bytes.bytesize)
    end

    def sent(exchange, folder, args)
      held = folder[args["path"]]
      return exchange.refuse!("no such file") if held.nil?

      offset = args["offset"].to_i
      part = held.bytes.byteslice(offset, args["length"] || held.bytes.bytesize).to_s
      (0...part.bytesize).step(Resource::Machine::MOST_CHUNKED).each_with_index do |from, seq|
        exchange.receive!(seq, part.byteslice(from, Resource::Machine::MOST_CHUNKED))
      end

      said = { "size" => part.bytesize }
      said = said.merge("offset" => offset, "total" => held.bytes.bytesize) if args.key?("offset")
      exchange.answer!(said)
    end

    def removed(exchange, folder, args)
      removing&.call(folder, args)
      held = folder[args["path"]]
      return exchange.refuse!("no such file") if held.nil?
      return exchange.refuse!("the file does not match the SHA-256 xixo named") unless Digest::SHA256.hexdigest(held.bytes) == args["sha256"]

      folder.delete(args["path"])
      exchange.answer!("path" => args["path"], "size" => held.bytes.bytesize, "pruned" => [])
    end

    def writer(machine_id, exchange, args)
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          Tenant.switch(@tenant) { written(machine_id, exchange, args) }
        end
      end
    end

    def written(machine_id, exchange, args)
      folder = @folders.dig(machine_id, args["folder"])
      return exchange.refuse!("this folder is not shared") if folder.nil?
      return exchange.refuse!("a file already exists there") if folder.key?(args["path"]) && !args["replace"]

      upload = LinkExchange.relayed(Resource::Machine.find(machine_id), args["upload"])
      return exchange.refuse!("no such upload") if upload.nil?

      received = fetched(upload, args["size"])
      return exchange.refuse!("the upload stalled") if received.nil?

      received.setbyte(0, received.getbyte(0) ^ 0xff) if corrupting && received.bytesize.positive?
      folder[args["path"]] = Held.new(received, args["modified_at"] ? Time.iso8601(args["modified_at"]) : Time.current)
      exchange.answer!("path" => args["path"], "size" => received.bytesize, "modified_at" => folder[args["path"]].modified_at.utc.iso8601)
    end

    def fetched(upload, size)
      received = "".b
      deadline = 30.seconds.from_now

      while received.bytesize < size
        return nil if Time.current > deadline

        part = upload.part!(received.bytesize)
        part.empty? ? sleep(0.02) : received << part
      end

      received
    end
end
