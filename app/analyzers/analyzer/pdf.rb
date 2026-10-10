module Analyzer
  class Pdf < Base
    def self.handles?(feed)
      feed.mime == "application/pdf"
    end

    def self.parse_info(output)
      output.lines.each_with_object({}) do |line, info|
        field, value = line.split(":", 2)
        next if value.nil?

        info[field.strip.downcase.tr(" ", "_")] = value.strip
      end.slice("pages", "title", "author", "creationdate", "page_size")
    end

    OCR_PAGES = 30
    OCR_DPI = "200".freeze
    SPARSE = 40
    READ_AS = "text layer, then ocr past #{SPARSE} characters a page".freeze

    def analyze
      with_tempfile do |path|
        info = step(:info) { Pdf.parse_info(run_command("pdfinfo", path)) }
        step(:text, digest: READ_AS) { readable(path, info.to_h["pages"].to_i) }
      end
    end

    private

      def readable(path, pages)
        layered = run_command("pdftotext", "-q", path, "-").strip
        return capped(layered) unless sparse?(layered, pages)

        recognized(path, pages).presence&.then { |text| capped(text) } || layered
      end

      def sparse?(text, pages)
        text.gsub(/\s/, "").length < SPARSE * [ pages, 1 ].max
      end

      def recognized(path, pages)
        last = pages.positive? ? [ pages, OCR_PAGES ].min : OCR_PAGES
        left_out("pages", "OCR read the first #{OCR_PAGES} of its #{pages} pages") if pages > OCR_PAGES

        Dir.mktmpdir do |dir|
          run_command("pdftoppm", "-r", OCR_DPI, "-gray", "-png", "-f", "1", "-l", last.to_s, path, File.join(dir, "page"))

          read = Dir[File.join(dir, "page*.png")].sort.map { |page| run_command("tesseract", page, "stdout").strip }
          analysis&.log_info(log_context, "text", "no text layer, so ocr read #{read.size} #{"page".pluralize(read.size)}")

          read.compact_blank.join("\n\n")
        end
      end
  end
end
