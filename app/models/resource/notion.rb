class Resource
  class Notion < Api
    API = "https://api.notion.com/v1".freeze
    VERSION = "2022-06-28".freeze
    DEPTH = 3
    BLOCKS = 100
    MAX_BLOCKS = 2_000
    UNTITLED = "Untitled".freeze
    ID = /\A\h{8}-?\h{4}-?\h{4}-?\h{4}-?\h{12}\z/

    PREFIXES = {
      "heading_1" => "# ", "heading_2" => "## ", "heading_3" => "### ",
      "bulleted_list_item" => "- ", "numbered_list_item" => "1. ",
      "to_do" => "- [ ] ", "quote" => "> "
    }.freeze

    def self.api
      API
    end

    def self.service
      "Notion"
    end

    def self.attaching
      {
        label: "Notion",
        blurb: "Every page the integration has been shared with, each one an item carrying its " \
               "text. Pages are shared with an integration from Notion, not from here.",
        names: "A name for it",
        fields: [
          token_field("Internal integration secret",
                      help: "From the integration's page under Notion's settings.",
                      placeholder: "ntn_…"),
          field("query", "Only pages matching", help: "Left empty, every shared page is catalogued.")
        ]
      }
    end

    def self.command_schema
      {
        list: { query: "string?", limit: "integer?" },
        get: { id: "string" },
        keep: { id: "string" }
      }
    end

    def check!
      bot = api_get("/users/me")

      raise Resource::Unusable, "#{key}: the secret names no integration" if bot["id"].blank?

      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      held = cursor.presence

      loop do
        found = search(held)
        pages = Array(found["results"]).select { |result| result["object"] == "page" }
        held = found["next_cursor"]

        yield pages, held if pages.any?

        break unless found["has_more"] && held.present?
      end
    end

    def object_for(id)
      wanted = id.to_s.delete_prefix("pages/")

      raise ArgumentError, "#{id} is not a Notion page id" unless wanted.match?(ID)

      page = api_get("/pages/#{wanted}")

      if page["object"] != "page" || page["archived"] || page["in_trash"]
        raise Api::Gone, "#{key}: #{id} is not a page Notion still has"
      end

      page
    end

    def locator_for(page)
      {
        "id" => page["id"],
        "url" => page["url"],
        "title" => title_for(page),
        "last_edited_time" => page["last_edited_time"],
        "parent" => page.dig("parent", "type")
      }
    end

    def locator_key_for(page)
      return page.to_s unless page.is_a?(Hash)

      "pages/#{page['id']}"
    end

    def version_for(locator)
      locator.to_h["last_edited_time"].presence
    end

    def mime_for(_page)
      "text/markdown"
    end

    def title_for(page)
      return page.to_s unless page.is_a?(Hash)

      titled(page).presence || UNTITLED
    end

    def download(locator)
      id = locator.fetch("id")

      StringIO.new(flattened(locator["title"], written(id)))
    end

    def command_list(query: nil, limit: nil)
      count = (limit || 30).to_i.clamp(1, BLOCKS)
      found = search(nil, query: query, page_size: count)

      {
        "pages" => Array(found["results"]).select { |result| result["object"] == "page" }
                                          .first(count).map { |page| described(page) }
      }
    end

    def command_keep(id:) = kept(id)

    def command_get(id:)
      page = object_for(id)

      described(page).merge("text" => written(page["id"]))
    end

    private

      def headers
        super.merge("Notion-Version" => VERSION)
      end

      def search(cursor, query: nil, page_size: BLOCKS)
        body = {
          page_size: page_size,
          filter: { value: "page", property: "object" }
        }

        wanted = query.presence || details["query"].presence
        body[:query] = wanted if wanted
        body[:start_cursor] = cursor if cursor.present?

        api_post("/search", body)
      end

      def written(id, depth: DEPTH)
        return "" if depth.zero?

        blocks(id).map { |block| said(block, depth) }.compact_blank.join("\n")
      end

      def blocks(id, cursor = nil, held = [])
        found = api_get("/blocks/#{id}/children", page_size: BLOCKS, start_cursor: cursor)
        held += Array(found["results"])

        return held unless found["has_more"] && found["next_cursor"].present? && held.length < MAX_BLOCKS

        blocks(id, found["next_cursor"], held)
      rescue Api::Gone
        held
      end

      def said(block, depth)
        type = block["type"].to_s
        line = spoken(block.dig(type, "rich_text"))
        line = "#{PREFIXES[type]}#{line}" if line.present?
        line = child_title(block, type) if line.blank?

        return line if block["has_children"].blank?

        [ line, indented(written(block["id"], depth: depth - 1)) ].compact_blank.join("\n")
      end

      def child_title(block, type)
        block.dig(type, "title") if type.start_with?("child_")
      end

      def indented(text)
        text.to_s.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
      end

      def spoken(rich_text)
        Array(rich_text).map { |span| span["plain_text"] }.join.strip
      end

      def titled(page)
        property = Array(page["properties"].to_h.values).find { |held| held["type"] == "title" }

        spoken(property.to_h["title"])
      end

      def described(page)
        {
          "id" => page["id"],
          "title" => title_for(page),
          "url" => page["url"],
          "last_edited_time" => page["last_edited_time"]
        }
      end
  end
end
