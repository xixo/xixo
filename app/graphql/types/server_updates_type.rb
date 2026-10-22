# frozen_string_literal: true

module Types
  class ServerUpdatesType < Types::BaseObject
    grants "xixo:settings:read"

    description "How xixo-updater keeps this server on the builds CI signed. Manual when no updater runs beside it."

    field :manual, Boolean, null: false, description: "Whether no updater reports to this server, so it is updated by hand."
    field :channel, String, description: "main, which follows every push, or releases, which follows the highest release."
    field :paused, Boolean, null: false, description: "Whether updates are paused."
    field :checked_at, String, description: "When the updater last looked for a new build."
    field :images, [ Types::ServerImageType ], null: false, description: "Each image the updater keeps up to date."
    field :events, [ Types::ServerUpdateEventType ], null: false, description: "The last ten things the updater did, newest first."

    def manual = object[:status].nil?
    def channel = object[:status]&.dig("channel")
    def paused = object[:status]&.dig("paused") == true
    def checked_at = object[:status]&.dig("checked_at")

    def images
      targets = object[:status]&.dig("targets")
      targets = {} unless targets.is_a?(Hash)

      Array(object[:status]&.dig("kinds")).select { |held| held.is_a?(Hash) }.map do |held|
        held.merge("target" => targets[held["name"]])
      end
    end

    def events = object[:events]
  end
end
