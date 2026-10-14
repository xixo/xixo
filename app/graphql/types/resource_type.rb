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
    field :offline, Boolean, null: false, method: :offline?,
          description: "Whether the machine it lives on was offline on its transport at the last check or sync. " \
                       "Its checks ask only the transport, and its scheduled syncs wait, until the machine is back."
    field :offline_host, String,
          description: "The name of the machine that is offline."
    field :offline_last_seen_at, GraphQL::Types::ISO8601DateTime,
          description: "When the transport last saw the machine that is offline. Empty for one it has never seen."
    field :emptied_at, GraphQL::Types::ISO8601DateTime,
          description: "When its last full sync found nothing where an earlier one found files. That sync marks " \
                       "nothing gone, so a folder whose disk was missing keeps its items. Empty once a full sync " \
                       "finds files again."
    field :checking, Boolean, null: false, method: :checking?,
          description: "Whether a check that asked more than whether it answers is still running. " \
                       "Its last finished check stays in checkedAt and checkError until this one ends."
    field :settings, GraphQL::Types::JSON, null: false,
          description: "What each field the type declares holds, for the fields kept in the clear. " \
                       "Nothing held encrypted is ever read back."
    field :changeable, Boolean, null: false,
          description: "Whether it has a form to change. A type xixo makes for itself does not."
    field :manageable, Boolean, null: false,
          description: "Whether this token changes it, puts it away, or deletes it. A person manages their own " \
                       "personal resources, and an administrator also manages every shared one."
    field :personal, Boolean, null: false, method: :personal?,
          description: "Whether only the person who attached it can see and use it."
    field :for_operators, Boolean, null: false, method: :for_operators?,
          description: "Whether only the people who operate the machine it is on see it and what it cataloged. " \
                       "A folder a machine shares starts this way, and an administrator can show it to everyone."
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
    field :machine, Types::MachineType,
          description: "What xixo link on the machine last said, for a machine running xixo link. Empty for " \
                       "every other type."
    field :machine_id, ID,
          description: "The machine it lives on or is reached through. A folder names the machine running xixo " \
                       "link that shares it. One reached over a tailnet names the linked machine at the address it " \
                       "dials, when one is. Everything else names this server, the machine xixo runs on. Empty for " \
                       "a machine, and for anything when this server has no machine yet."
    field :sight, String,
          description: "For a model backend, which of its models describes images, or why none does and " \
                       "which model to set. Empty for every other type."
    field :movable, Boolean, null: false,
          description: "Whether files move in and out of it: a folder that a machine running xixo link shares " \
                       "writable. The link-up command shares a folder writable when it is named with :rw."
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

    def machine
      object if object.is_a?(Resource::Machine)
    end

    def sight
      object.try(:sight_said)
    end

    def movable
      object.is_a?(Resource::Filesystem) && object.writable?
    end

    def manageable
      object.managed_by?(context[:grant])
    end

    def changeable
      Array(object.class.attaching&.fetch(:fields)).any?
    end

    def held_credentials
      declared(:credentials).map { |field| field[:name] }.select { |name| object.credentials.to_h[name].present? }
    end

    def machine_id
      dataloader.with(Sources::MachineOf).load(object)
    end

    def items_count
      dataloader.with(Sources::ItemsCount).load(object.id)
    end

    private

      def declared(held)
        Array(object.class.attaching&.fetch(:fields)).select { |field| field[:held] == held }
      end
  end
end
