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

    def analyze
      as_pdf do |pdf|
        step(:info) { Pdf.parse_info(run_command("pdfinfo", pdf)) }
        step(:text) { capped(run_command("pdftotext", "-q", pdf, "-").strip) }
      end
    end

    private

      def as_pdf
        with_tempfile do |source|
          Dir.mktmpdir do |dir|
            run_command("soffice", "-env:UserInstallation=file://#{File.join(dir, 'profile')}",
                        "--headless", "--convert-to", "pdf", "--outdir", dir, source)

            pdf = Dir[File.join(dir, "*.pdf")].first
            raise Analyzer::Failed, "libreoffice produced no pdf" if pdf.nil?

            yield pdf
          end
        end
      end
  end
end
