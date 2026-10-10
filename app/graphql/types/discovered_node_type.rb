# frozen_string_literal: true

module Types
  class DiscoveredNodeType < Types::BaseObject
    grants "xixo:resources:read"

    description "A machine a transport reaches, as its network names it. Nothing else the network " \
                "knows about it, such as its keys, its owner, or its operating system, is read back."

    field :host_name, String, description: "The name the machine gives itself."
    field :dns_name, String, description: "Its full name on the network, when the network names it."
    field :addresses, [ String ], null: false, description: "Its addresses on the network, IPv4 first."
    field :online, Boolean, null: false, description: "Whether the network sees it now."
    field :last_seen_at, GraphQL::Types::ISO8601DateTime,
          description: "When the network last saw it, for a machine that is offline.", hash_key: "last_seen"
    field :services, [ Types::DiscoveredServiceType ], null: false,
          description: "The well-known ports that answered when the machine was asked. Empty for a " \
                       "machine that is offline, or when the ports were not asked."
    field :address, String, description: "What the address field of a type would hold to reach it. " \
                                         "Empty for a type that cannot be reached through a transport." do
      argument :type, String, required: true
    end

    def services
      Array(object["services"])
    end

    def address(type:)
      klass = Resource.attachable.find { |held| held.sti_name == type }
      first = object["addresses"].first
      klass && first && klass.address_on(first)
    end
  end
end
