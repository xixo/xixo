require "rubygems/package"
require "zip"
require "zlib"

module Analyzer
  class Fallback < Base
    SNIFF = 8_192
    CONTROL = 0.01
    CONTROL_CHARS = /[\x00-\x08\x0b\x0c\x0e-\x1f]/
    TAR_MAGIC = "ustar".b
    TAR_MAGIC_AT = 257
    PAX_TYPES = %w[x g].freeze
    LISTING = 200
    SHOWN = 50

    MAGIC = {
      "PK\x03\x04" => "zip",
      "\x1f\x8b" => "gzip",
      "%PDF" => "pdf",
      "\x7fELF" => "executable",
      "ID3" => "audio",
      "OggS" => "audio",
      "RIFF" => "media",
      "\x89PNG" => "image"
    }.freeze

    MARKUP = /\.(html?|xhtml|svg|xml)\z/i

    def self.handles?(_feed)
      true
    end

    def self.summary_role
      :fast
    end

    def analyze
      step(:size) { { "bytes" => reference.download.size } }
      step(:format) { sniffed }

      step(:text) { legible } if printable?
      step(:listing) { entries } if archive?
    end

    def summary_body
      text = step_result(:text).to_s.strip
      return fenced(text) if text.present?

      names = Array(step_result(:listing))
      return fenced("Archive entries:\n#{names.first(SHOWN).join("\n")}") if names.any?

      UNREAD
    end

    def file_facts
      [ super, format_facts ].compact_blank.join("\n")
    end

    private

      def head
        @head ||= reference.download.read(SNIFF).to_s.b
      end

      def sniffed
        {
          "declared" => reference.content_type,
          "observed" => observed,
          "printable" => printable?
        }
      end

      def observed
        found = MAGIC.find { |prefix, _name| head.start_with?(prefix.b) }
        return found.last if found
        return "tar" if tarred?(head)

        printable? ? "text" : "binary"
      end

      def printable?
        return @printable if defined?(@printable)

        @printable = legible?(head)
      end

      def legible?(sample)
        return false if sample.blank?

        text = utf8(sample)
        return false if text.nil?

        text.scan(CONTROL_CHARS).length.to_f / text.length < CONTROL
      end

      def utf8(sample)
        3.times do |dropped|
          held = sample.byteslice(0, sample.bytesize - dropped).to_s.dup
          held.force_encoding(Encoding::UTF_8)
          return held if held.valid_encoding? && held.length.positive?
        end

        nil
      end

      def archive?
        case observed
        when "zip", "tar" then true
        when "gzip" then tarred?(inflated_head)
        else false
        end
      end

      def tarred?(bytes)
        bytes.byteslice(TAR_MAGIC_AT, TAR_MAGIC.bytesize) == TAR_MAGIC
      end

      def inflated_head
        @inflated_head ||= Zlib::Inflate.new(Zlib::MAX_WBITS + 32).inflate(head).b
      rescue Zlib::Error
        @inflated_head = "".b
      end

      def legible
        body = reference.download.read.to_s.force_encoding(Encoding::UTF_8).scrub
        body = Markup.strip(body) if markup?(body)

        body.strip.truncate(MAX_TEXT)
      end

      def markup?(body)
        reference.filename.match?(MARKUP) || body.lstrip.start_with?("<")
      end

      def format_facts
        found = step_result(:format).to_h
        return nil if found.blank?

        declared = found["declared"].to_s
        seen = found["observed"]
        return "Format: #{seen}" if declared.blank? || declared == "application/octet-stream"

        "Format: #{seen}, declared as #{declared}"
      end

      def entries
        with_tempfile do |path|
          case observed
          when "zip" then Zip::File.open(path) { |zip| zip.entries.first(LISTING).map(&:name) }
          when "tar" then File.open(path, "rb") { |file| tar_entries(file) }
          else Zlib::GzipReader.open(path) { |gzip| tar_entries(gzip) }
          end
        end
      rescue StandardError => e
        raise Analyzer::Failed, "unreadable archive: #{e.message.truncate(200)}"
      end

      def tar_entries(io)
        Gem::Package::TarReader.new(io).each.lazy
          .reject { |entry| PAX_TYPES.include?(entry.header.typeflag) || apple_double?(entry.full_name) }
          .first(LISTING).map(&:full_name)
      end

      def apple_double?(name)
        File.basename(name).start_with?("._")
      end
  end
end
