# frozen_string_literal: true

module Types
  class LinkUpdatesType < Types::BaseObject
    grants "xixo:settings:read"

    description "How xixo link on each machine is kept on the release this xixo ships."

    field :release, String, description: "The version of xixo link this xixo ships. Empty when it ships none."
    field :protocol, Integer, null: false, description: "The protocol this xixo speaks. It accepts links one behind it."
    field :rollout, Types::LinkRolloutType, description: "The rollout of the shipped release. Empty when this xixo ships no signed release description."
    field :machines, [ Types::ResourceType ], null: false, description: "Every machine running xixo link, the one beside the server included."

    def release = Resource::Machine::Downloads.version
    def protocol = Resource::Machine::Updates::PROTOCOL
    def rollout = LinkRollout.current!

    def machines
      Resource::Machine.active.order(:name, :id)
    end
  end
end
