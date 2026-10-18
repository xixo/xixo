# frozen_string_literal: true

module Types
  class DiscoveredNodeType < Types::BaseObject
    grants "xixo:resources:read"

    description "What a transport reaches, as it names it. For a machine running xixo link, each folder it shares."

    field :host_name, String, description: "The name the machine gives itself."
    field :dns_name, String, description: "Its full name, when the transport names one."
    field :addresses, [ String ], null: false, description: "Its addresses, IPv4 first. Empty for a folder."
    field :online, Boolean, null: false, description: "Whether the transport reaches it now."
    field :last_seen_at, GraphQL::Types::ISO8601DateTime,
          description: "When the network last saw it, for a machine that is offline.", hash_key: "last_seen"
    field :via, String, description: "The key of the transport that reaches it.", hash_key: "via"
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
