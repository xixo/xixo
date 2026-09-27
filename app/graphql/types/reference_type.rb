# frozen_string_literal: true

module Types
  class ReferenceType < Types::BaseObject
    grants "uris:catalog:read"

    field :id, ID, null: false
    field :resource, Types::ResourceType, null: false
    field :locator, GraphQL::Types::JSON, null: false
    field :locator_key, String
    field :filename, String, null: false
    field :content_type, String, null: false
    field :version, String
    field :changed_at, GraphQL::Types::ISO8601DateTime
    field :analyzed_at, GraphQL::Types::ISO8601DateTime
    field :gone_at, GraphQL::Types::ISO8601DateTime,
          description: "When a sync of its resource last walked everything and did not find it."
    field :role, String, null: false
    field :mime, String
    field :size, GraphQL::Types::BigInt
    field :content_url, String, null: false
    field :thumbnail_url, String
    field :hires_url, String,
          description: "The large image rendered from it, no longer on its longest edge than the hi-res size setting."

    def content_url
      "/references/#{object.id}/content"
    end

    def thumbnail_url
      derived(Reference::THUMBNAIL)
    end

    def hires_url
      derived(Reference::PREVIEW)
    end

    private

      def derived(role)
        return nil unless object.role == Reference::ORIGINAL

        held = object.feed.references.find { |reference| reference.role == role }

        "/references/#{held.id}/content" if held
      end
  end
end
