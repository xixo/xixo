module FakeAgent
  RECORDED = Rails.root.join("test/fixtures/extractions")
  JPEG = Base64.decode64(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////" \
    "wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
  ).freeze
  WAV = ("RIFF".b + [ 36 ].pack("V") + "WAVEfmt ".b + [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") +
         "data".b + [ 0 ].pack("V")).freeze
  PLACEHOLDERS = { "thumbnail" => JPEG, "preview" => JPEG, "frame" => JPEG, "audio" => WAV }.freeze

  Asked = Data.define(:verb, :args, :bytes)

  class Answer
    attr_reader :result

    def initialize(result, held)
      @result = result
      @held = held
    end

    def files
      Array(result["files"])
    end

    def file(entry)
      Tempfile.new("fake-agent", binmode: true).tap do |file|
        file.write(@held.fetch(entry["request_file"]))
        file.rewind
      end
    end
  end

  class Local
    attr_accessor :extractors

    def initialize
      @extractors = Resource::XixoAgent::EXTRACTORS
    end

    def key = "local"
    def name = "This server"
    def connected? = true
    def offered_folders = []
    def extracts?(kind) = extractors.include?(kind.to_s)

    def upload(io)
      FakeAgent.upload(io)
    end

    def forget(request)
      FakeAgent.forgotten << request
    end

    def exchanged(verb, args = {}, within: nil)
      yield FakeAgent.answer(verb, args)
    end
  end

  module Standing
    def local
      super || (FakeAgent.standing ? FakeAgent.local : nil)
    end
  end

  class << self
    attr_accessor :standing, :script
    attr_reader :local, :asked, :forgotten

    def reset!
      @standing = true
      @script = nil
      @local = Local.new
      @uploads = {}
      @asked = []
      @forgotten = []
    end

    def upload(io)
      id = SecureRandom.uuid
      @uploads[id] = io.read.to_s.b

      { "upload" => id, "size" => @uploads[id].bytesize }
    end

    def answer(verb, args)
      bytes = @uploads.delete(args.dig("source", "upload")).to_s.b
      asked << Asked.new(verb: verb, args: args, bytes: bytes)

      result, held = script&.call(verb, args, bytes) || recorded(bytes) || made(verb, args, bytes)
      Answer.new(result.deep_stringify_keys, held.to_h)
    end

    def extracted(steps, files: [], dropped: {}, extractor: "text")
      held = {}
      listed = files.each_with_index.map do |file, index|
        id = SecureRandom.uuid
        body = file[:body] || placeholder(file.stringify_keys)
        held[id] = body.b
        file.except(:body).merge(request_file: id, size: body.bytesize, mime: file[:mime] || "image/jpeg")
      end

      [ { extractor: extractor, steps: steps.transform_values { |value| { result: value } }, dropped: dropped, files: listed }, held ]
    end

    def placeholder(file)
      PLACEHOLDERS.fetch(file["role"].to_s, "".b) + file["name"].to_s.b
    end

    private

      def recorded(bytes)
        path = RECORDED.join("#{Digest::SHA256.hexdigest(bytes)}.json")
        return nil unless path.exist?

        held = JSON.parse(path.read)
        raise Resource::XixoAgent::Refusal, "local: the agent said #{held['error']}" if held["result"].nil?

        result = held["result"]
        bodies = Array(result["files"]).to_h do |file|
          kept = held.dig("kept", file["request_file"])
          [ file["request_file"], kept ? RECORDED.join("files", kept).binread : placeholder(file) ]
        end

        [ result, bodies ]
      end

      def made(verb, args, bytes)
        return extracted({}, extractor: "derive") if verb == "derive"

        mime = args["mime"].to_s
        return emailed(bytes) if mime == "message/rfc822"
        return extracted({ "text" => decoded(bytes).strip }) if readable?(mime)

        printable = printable?(bytes)
        steps = { "size" => { "bytes" => bytes.bytesize },
                  "format" => { "declared" => mime, "observed" => printable ? "text" : "binary", "printable" => printable } }
        steps["text"] = decoded(bytes).strip if printable

        extracted(steps, extractor: "fallback")
      end

      def printable?(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? && text.present? && text.count("\x00-\x08\x0b\x0c\x0e-\x1f") < text.length * 0.01
      end

      def emailed(bytes)
        message = Mail.read_from_string(decoded(bytes))
        part = message.multipart? ? (message.text_part || message.html_part) : message
        said = [ message.subject, part&.decoded.to_s.scrub ].compact.join("\n\n").strip
        children = message.attachments.map do |attachment|
          { role: "child", name: attachment.filename, mime: attachment.mime_type, body: attachment.body.decoded }
        end

        ids = [ message.message_id, *Array(message.in_reply_to), *Array(message.references) ].compact.map(&:to_s).uniq

        extracted({ "headers" => { "from" => message.from&.join(", "), "subject" => message.subject,
                                   "date" => message.date&.iso8601 }.compact,
                    "thread" => { "ids" => ids }, "text" => said }, files: children, extractor: "email")
      end

      def readable?(mime)
        (MimeType.text?(mime) && !%w[text/calendar text/vcard].include?(mime)) ||
          %w[application/json application/xml].include?(mime)
      end

      def decoded(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : bytes.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
      end
  end
end

Resource::XixoAgent.singleton_class.prepend(FakeAgent::Standing)
FakeAgent.reset!
