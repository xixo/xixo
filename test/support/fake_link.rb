module FakeLink
  RECORDED = Rails.root.join("test/fixtures/extractions")
  JPEG = Base64.decode64(
    "/9j/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC" \
    "8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAA" \
    "AQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2" \
    "JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKz" \
    "tLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtR" \
    "EAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK" \
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5e" \
    "bn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwAooooA/9k="
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
      Tempfile.new("fake-link", binmode: true).tap do |file|
        file.write(@held.fetch(entry["request_file"]))
        file.rewind
      end
    end
  end

  class Local
    attr_accessor :extractors

    def initialize
      @extractors = Resource::Machine::EXTRACTORS
    end

    def id = nil
    def key = "local"
    def name = "Hub"
    def local? = true
    def reads_for_others? = true
    def connected? = true
    def offered_folders = []
    def extracts?(kind) = extractors.include?(kind.to_s)

    def upload(io)
      FakeLink.upload(io)
    end

    def forget(request)
      FakeLink.forgotten << request
    end

    def exchanged(verb, args = {}, within: nil)
      yield FakeLink.answer(verb, args)
    end
  end

  module Standing
    def pool
      super.presence || (FakeLink.standing ? [ FakeLink.local ] : [])
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
      return shaded(file["name"].to_s) if file["role"].to_s == "frame"

      PLACEHOLDERS.fetch(file["role"].to_s, "".b) + file["name"].to_s.b
    end

    def shaded(name)
      require "vips"

      shade = Digest::SHA256.digest(name).bytes.first
      (Vips::Image.black(8, 8, bands: 3) + shade).cast(:uchar).jpegsave_buffer(Q: 90)
    end

    private

      def recorded(bytes)
        path = RECORDED.join("#{Digest::SHA256.hexdigest(bytes)}.json")
        return nil unless path.exist?

        held = JSON.parse(path.read)
        raise Resource::Machine::Refusal, "local: xixo link said #{held['error']}" if held["result"].nil?

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

Resource::Machine.singleton_class.prepend(FakeLink::Standing)
FakeLink.reset!
