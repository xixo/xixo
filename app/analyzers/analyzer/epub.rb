require "zip"

module Analyzer
  class Epub < Base
    MIME = "application/epub+zip".freeze
    CONTAINER = "META-INF/container.xml".freeze
    ENCRYPTION = "META-INF/encryption.xml".freeze
    MAX_ENTRY = 8.megabytes
    MAX_CHAPTERS = 1_000
    LISTED = %w[creator contributor subject].freeze
    SINGLE = %w[title publisher date language identifier description].freeze
    BLOCKS = %w[p div h1 h2 h3 h4 h5 h6 li br tr blockquote section article pre].freeze

    def self.handles?(feed)
      feed.mime == MIME
    end

    def analyze
      opened do |zip|
        book = step(:book) { describe(zip) }

        step(:text) { [ facts(book), chapters(zip, book) ].compact_blank.join("\n\n").truncate(MAX_TEXT) }
      end
    end

    def summary_noun
      "book"
    end

    private

      def opened(&block)
        with_tempfile { |path| Zip::File.open(path, &block) }
      rescue Zip::Error => e
        raise Analyzer::Failed, "unreadable epub: #{e.message.truncate(200)}"
      end

      def describe(zip)
        root = package_path(zip)
        package = xml(entry_text(zip, root) || raise(Analyzer::Failed, "#{root} is missing from the epub"))
        metadata = package.at("metadata")

        SINGLE.to_h { |field| [ field, metadata&.at(field)&.text&.squish.presence ] }
              .merge(LISTED.to_h { |field| [ "#{field}s", metadata ? metadata.search(field).map { |node| node.text.squish }.compact_blank : [] ] })
              .merge("chapters" => spine(package, File.dirname(root)), "encrypted" => encrypted(zip))
              .compact_blank
      end

      def package_path(zip)
        container = entry_text(zip, CONTAINER)
        named = container && xml(container).at("rootfile")&.[]("full-path")

        named.presence || zip.entries.map(&:name).find { |name| name.end_with?(".opf") } ||
          raise(Analyzer::Failed, "the epub names no package document")
      end

      def spine(package, base)
        items = package.search("manifest item").to_h { |item| [ item["id"], item ] }

        package.search("spine itemref").filter_map do |reference|
          item = items[reference["idref"]]
          next unless item && item["media-type"].to_s.include?("html") && item["href"].present?

          inside(base, item["href"])
        end.uniq.first(MAX_CHAPTERS)
      end

      def encrypted(zip)
        listed = entry_text(zip, ENCRYPTION)
        return [] if listed.nil?

        xml(listed).search("CipherReference").filter_map { |cipher| cipher["URI"].presence }
                   .map { |uri| inside(".", uri) }
      end

      def chapters(zip, book)
        skipped = Array(book["encrypted"])
        collected = []
        length = 0

        Array(book["chapters"]).each do |path|
          break if length >= MAX_TEXT
          next if skipped.include?(path)

          text = readable(entry_text(zip, path))
          next if text.blank?

          collected << text
          length += text.length
        end

        collected.join("\n\n")
      end

      def facts(book)
        [
          ("Title: #{book['title']}" if book["title"]),
          ("By: #{book['creators'].join(', ')}" if book["creators"]),
          ("With: #{book['contributors'].join(', ')}" if book["contributors"]),
          ("Publisher: #{book['publisher']}" if book["publisher"]),
          ("Published: #{book['date']}" if book["date"]),
          ("Language: #{book['language']}" if book["language"]),
          ("Subjects: #{book['subjects'].join(', ')}" if book["subjects"]),
          ("Description: #{Markup.strip(book['description'])}" if book["description"]),
          ("Its chapters are encrypted, so only its details could be read." if encrypted_throughout?(book))
        ].compact.join("\n")
      end

      def encrypted_throughout?(book)
        chapters = Array(book["chapters"])
        chapters.any? && (chapters - Array(book["encrypted"])).empty?
      end

      def readable(body)
        return nil if body.nil?

        document = xml(body)
        root = document.at("body") || document.root
        return nil if root.nil?

        root.search("script, style").remove
        root.search(BLOCKS.join(", ")).each { |node| node.add_next_sibling("\n") }

        root.text.lines.map(&:squish).compact_blank.join("\n")
      end

      def entry_text(zip, name)
        entry = zip.find_entry(name)
        return nil if entry.nil? || !entry.file?
        raise Analyzer::Failed, "#{name} is larger than #{MAX_ENTRY / 1.megabyte} MB" if entry.size > MAX_ENTRY

        entry.get_input_stream.read(MAX_ENTRY).to_s.force_encoding(Encoding::UTF_8).scrub
      end

      def inside(base, href)
        path = CGI.unescape(href.to_s.split("#").first.to_s)
        Pathname.new(base).join(path).cleanpath.to_s.delete_prefix("./")
      end

      def xml(body)
        Nokogiri::XML(body).tap(&:remove_namespaces!)
      end
  end
end
