# frozen_string_literal: true

module Types
  class FeedType < Types::BaseObject
    grants "uris:catalog:read"

    SUMMARY = 400
    CITATION = /\s*\[feed\s*:?\s*\d+\]/i
    CONNECTED = 200

    field :id, ID, null: false
    field :type, String, null: false,
          description: "What it is, and how it renders: uris:file, uris:note, uris:feed, uris:tag, uris:mime."
    field :key, String, null: false,
          description: "Its name within its type — README.md, text/markdown, /buy."
    field :origin, String, null: false,
          description: "resource when synced from one, feed when an analysis minted it."
    field :title, String
    field :mime, String, description: "The content type of the bytes, when it has any."
    field :references, [ Types::ReferenceType ], null: false
    field :analyzed_at, GraphQL::Types::ISO8601DateTime
    field :note, String, description: "What you wrote about it, in your own words."
    field :expires_at, GraphQL::Types::ISO8601DateTime,
          description: "When it is forgotten, unless it is kept. Null for a feed that lasts forever."
    field :summary, String,
          description: "What a model made of it, or until one has, the start of the text read out of it."
    field :details, [ Types::DetailType ], null: false,
          description: "Everything its last analysis read out of it that has a name and a value, " \
                       "such as embedded metadata, dimensions, and document info, grouped by where it came from."
    field :thumbnail_url, String
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false

    field :connected_count, Integer, null: false
    field :connected, [ Types::FeedType ], null: false
    field :tags, [ Types::FeedType ], null: false,
          description: "The tags it is filed under: those a person or agent chose, and those its analysis found in it. " \
                       "The tags most items share come first."
    field :mimes, [ Types::FeedType ], null: false,
          description: "The content types it was filed under, as feeds of their own."
    field :parent, Types::FeedType, description: "The file it was extracted from, when it was."
    field :children, [ Types::FeedType ], null: false,
          description: "What was extracted from it — the attachments of a message, the files of an archive."
    field :asked, Boolean, null: false,
          description: "A question someone asked the catalog, answered by its analyses."
    field :staged, Boolean, null: false,
          description: "Uploaded, and still waiting for the pass to decide where it is stored."
    field :timeout, Integer,
          description: "Seconds an analysis of it may run, when someone set it. Null gets the default."
    field :time_allowed, Integer, null: false,
          description: "Seconds an analysis of it may run before it is cut off, unless the agent asks for more, " \
                       "and never more than a day."
    field :schedule, Types::ScheduleType
    field :analyses, [ Types::AnalysisType ], null: false

    def time_allowed = object.time_allowed.to_i

    def summary
      object.summary || excerpt
    end

    def excerpt
      passed = object.analysis
      said = passed && (passed.step_result("text").presence || passed.step_result("ocr").presence)
      said = object.note if said.blank?

      said.to_s.gsub(CITATION, "").gsub(/[*`]+/, "").gsub(/[#>|\\]+/, " ").squish.truncate(SUMMARY).presence
    end

    def details
      Details.of(object.analysis)
    end

    def connected_count = object.edges.count

    def staged = object.staged?

    def asked = object.asked?

    def children
      object.children.limit(CONNECTED)
    end

    def connected
      object.connected.order(created_at: :desc).limit(CONNECTED)
    end

    def tags
      object.tags.by_use
    end

    def mimes
      object.mimes.order(:key)
    end

    def analyses
      object.analyses.newest_first.limit(20)
    end

    def thumbnail_url
      thumbnail = object.references.find { |held| held.role == Reference::THUMBNAIL }

      "/references/#{thumbnail.id}/content" if thumbnail
    end
  end
end
