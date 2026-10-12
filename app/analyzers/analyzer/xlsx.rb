module Analyzer
  class Xlsx < Base
    SHEETS = %w[
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      application/vnd.ms-excel
      application/vnd.oasis.opendocument.spreadsheet
    ].freeze

    def self.handles?(feed)
      SHEETS.include?(feed.mime)
    end

    SAYS = "two or three sentences on what this workbook holds. Name the sheets, " \
           "the columns and the organisations, people or periods the data covers, " \
           "in the words the workbook uses."

    def summary_says
      SAYS
    end
  end
end
