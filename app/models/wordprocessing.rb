require "zip"

module Wordprocessing
  DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document".freeze
  ODT = "application/vnd.oasis.opendocument.text".freeze
  READ = [ DOCX, ODT ].freeze
  MOST = 50.megabytes

  W = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze
  ODF = {
    "office" => "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "text" => "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
    "table" => "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
  }.freeze

  def self.reads?(mime)
    READ.include?(mime)
  end

  def self.text(path, mime)
    case mime
    when DOCX then docx(entry(path, "word/document.xml"))
    when ODT then odt(entry(path, "content.xml"))
    end
  end

  def self.entry(path, name)
    Zip::File.open(path) do |zip|
      found = zip.find_entry(name)
      found && found.size <= MOST ? found.get_input_stream.read(MOST) : nil
    end
  rescue Zip::Error
    nil
  end

  def self.docx(xml)
    body = xml && Nokogiri::XML(xml).at_xpath("//w:body", W)
    return nil if body.nil?

    joined(body.xpath("w:p | w:tbl", W).map { |node| node.name == "tbl" ? docx_table(node) : docx_paragraph(node) })
  end

  def self.docx_paragraph(paragraph)
    said = paragraph.xpath(".//w:t | .//w:tab | .//w:br", W).map do |run|
      { "t" => run.text, "tab" => "\t", "br" => "\n" }.fetch(run.name)
    end.join.strip
    return nil if said.empty?

    level = docx_level(paragraph)
    level ? "#{'#' * level} #{said.squish}" : said
  end

  def self.docx_level(paragraph)
    style = paragraph.at_xpath("w:pPr/w:pStyle/@w:val", W)&.value.to_s
    outline = paragraph.at_xpath("w:pPr/w:outlineLvl/@w:val", W)&.value

    return 1 if style.casecmp?("Title")
    return style[/\d+\z/].to_i.clamp(1, 6) if style.match?(/\Aheading\s*\d+\z/i)

    outline && (outline.to_i + 1).clamp(1, 6)
  end

  def self.docx_table(table)
    table.xpath("w:tr", W).map do |row|
      row.xpath("w:tc", W).map { |cell| cell.xpath(".//w:t", W).map(&:text).join.squish }.join(" | ")
    end.join("\n")
  end

  def self.odt(xml)
    body = xml && Nokogiri::XML(xml).at_xpath("//office:text", ODF)
    return nil if body.nil?

    joined(odt_blocks(body))
  end

  def self.odt_blocks(node)
    node.element_children.flat_map do |child|
      case child.name
      when "h" then odt_heading(child)
      when "p" then child.text.strip.presence
      when "table" then odt_table(child)
      when "list", "list-item", "section" then odt_blocks(child)
      else []
      end
    end
  end

  def self.odt_heading(heading)
    level = heading["text:outline-level"].to_i.clamp(1, 6)
    said = heading.text.squish
    said.empty? ? nil : "#{'#' * level} #{said}"
  end

  def self.odt_table(table)
    table.xpath(".//table:table-row", ODF).map do |row|
      row.xpath("table:table-cell", ODF).map { |cell| cell.text.squish }.join(" | ")
    end.join("\n")
  end

  def self.joined(blocks)
    Array(blocks).flatten.compact_blank.join("\n\n").presence
  end
end
