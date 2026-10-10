# frozen_string_literal: true

module Types
  class ResourceType < Types::BaseObject
    grants "xixo:resources:read"

    field :id, ID, null: false
    field :type, String, null: false, method: :type
    field :key, String, null: false
    field :name, String
    field :capabilities, [ String ], null: false
    field :items_count, Integer, null: false
    field :default_storage, Boolean, null: false
    field :default_inference, Boolean, null: false
    field :sync_interval, Integer
    field :next_sync_at, GraphQL::Types::ISO8601DateTime
    field :synced_at, GraphQL::Types::ISO8601DateTime
    field :syncing, Boolean, null: false, method: :syncing?
    field :syncable, Boolean, null: false, method: :syncable?,
          description: "Whether it enumerates what it holds. One that does not, like a " \
                       "browser, can neither be synced nor kept on a schedule."
    field :archived_at, GraphQL::Types::ISO8601DateTime
    field :checked_at, GraphQL::Types::ISO8601DateTime
    field :check_error, String
    field :healthy, Boolean, null: false, method: :healthy?
    field :checking, Boolean, null: false, method: :checking?,
          description: "Whether a check that asked more than whether it answers is still running. " \
                       "Its last finished check stays in checkedAt and checkError until this one ends."
    field :settings, GraphQL::Types::JSON, null: false,
          description: "What each field the type declares holds, for the fields kept in the clear. " \
                       "Nothing held encrypted is ever read back."
    field :changeable, Boolean, null: false,
          description: "Whether it has a form to change. A type xixo makes for itself does not."
    field :personal, Boolean, null: false, method: :personal?,
          description: "Whether only the person who attached it can see and use it."
    field :delegated, Boolean, null: false, method: :delegated?,
          description: "Whether it reaches somebody's account elsewhere through masks."
    field :needs_connect, Boolean, null: false, method: :needs_connect?,
          description: "Whether somebody has to connect it through masks, or connect it again, before it answers."
    field :connected_by, String,
          description: "The subject of whoever connected it."
    field :connect_url, String, method: :connect_path,
          description: "Where to send the browser to connect it, for a resource that connects through masks."
    field :via, String,
          description: "The key of the transport it is reached through. Empty for a resource reached directly."
    field :routable, Boolean, null: false,
          description: "Whether it can be reached through a transport, such as a tailnet."
    field :held_credentials, [ String ], null: false,
          description: "The names of the encrypted fields that hold something, so a form can say " \
                       "one is set without saying what it is."

    def capabilities
      object.capabilities.map(&:to_s)
    end

    def via
      object.via&.key
    end

    def routable
      object.class.routable?
    end

    def settings
      declared(:details).to_h do |field|
        [ field[:name], field[:name].split(".").reduce(object.details.to_h) { |held, step| held.is_a?(Hash) ? held[step] : nil } ]
      end.compact
    end

    def changeable
      Array(object.class.attaching&.fetch(:fields)).any?
    end

    def held_credentials
      declared(:credentials).map { |field| field[:name] }.select { |name| object.credentials.to_h[name].present? }
    end

    def items_count
      Reference.where(resource_id: object.id).distinct.count(:feed_id)
    end

    private

      def declared(held)
        Array(object.class.attaching&.fetch(:fields)).select { |field| field[:held] == held }
      end
  end
end
