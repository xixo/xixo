module Analyzer
  class Doc < Base
    DOCS = %w[
      application/msword
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.oasis.opendocument.text
    ].freeze

    def self.handles?(feed)
      DOCS.include?(feed.mime)
    end

    READ_AS = "headings and tables from the document itself, else the pdf's text".freeze

    def analyze
      as_pdf do |source, pdf|
        step(:info) { Pdf.parse_info(run_command("pdfinfo", pdf)) }
        step(:text, digest: READ_AS) { capped(written(source, pdf)) }
      end
    end

    private

      def written(source, pdf)
        headed = Wordprocessing.text(source, feed.mime) if Wordprocessing.reads?(feed.mime)
        headed.presence || run_command("pdftotext", "-q", pdf, "-").strip
      end

      def as_pdf
        with_tempfile do |source|
          Dir.mktmpdir do |dir|
            run_command("soffice", "-env:UserInstallation=file://#{File.join(dir, 'profile')}",
                        "--headless", "--convert-to", "pdf", "--outdir", dir, source)

            pdf = Dir[File.join(dir, "*.pdf")].first
            raise Analyzer::Failed, "libreoffice produced no pdf" if pdf.nil?

            yield source, pdf
          end
        end
      end
  end
end
