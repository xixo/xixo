# frozen_string_literal: true

module Types
  class LinkRequestType < Types::BaseObject
    grants "xixo:resources:read"

    description "A machine asking to link up. xixo link on the machine started it and shows its code. Only an " \
                "administrator approves or denies it, and it runs out after ten minutes."

    field :id, ID, null: false
    field :code, String, null: false, description: "The code the machine shows, such as WDJB-MJHT.", method: :user_code
    field :status, String, null: false,
          description: "pending, approved, handed (the machine took its enrollment token), linked, or denied."
    field :hostname, String, null: false, description: "The name the machine gives itself."
    field :os, String
    field :arch, String
    field :folders, [ String ], null: false, description: "The folders the machine's config shares."
    field :writable, [ String ], null: false, description: "The shared folders the machine marks writable."
    field :remote_ip, String, description: "The address the request came from."
    field :expires_at, GraphQL::Types::ISO8601DateTime, null: false
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :machine, Types::ResourceType, description: "The machine it linked up as, once it has.", method: :resource
    field :user, String, description: "The account xixo link runs as on the machine."
    field :system, String, description: "The system and its version, such as macOS 26.0 or Ubuntu 24.04 LTS."
    field :model, String, description: "The hardware model the machine reports, such as Mac14,7. Empty when it names none."
    field :version, String, description: "The version of xixo link asking."
    field :cpus, Integer, description: "How many processor cores the machine has."
    field :memory, GraphQL::Types::BigInt, description: "The machine's memory, in bytes."
    field :disks, [ Types::MachineDiskType ], null: false,
          description: "The disk under each shared folder, with its size and free space in bytes."
    field :addresses, [ String ], null: false, description: "The machine's own network addresses."
    field :services, [ Types::MachineServiceType ], null: false, description: "Model servers xixo link found on the machine."
    field :same_address, Boolean,
          description: "Whether the request came from the same address as the browser asking. Empty when xixo cannot tell."
    field :links_as, String, null: false, description: "The key the machine has, or gets when it is approved."
    field :named_like, String,
          description: "The key of a linked machine with the same name, while this request waits. Approving adds a second machine."

    %w[user system model version cpus memory].each do |name|
      define_method(name) { object.details[name] }
    end

    def disks = Array(object.details["disks"])
    def addresses = Array(object.details["addresses"])
    def services = Array(object.details["services"])

    def same_address
      asking = context[:remote_ip]
      object.remote_ip == asking if asking.present? && object.remote_ip.present?
    end

    def links_as = object.resource&.key || Resource::Machine.free_key(object.hostname)

    def named_like
      Resource::Machine.find_by(key: Resource::Machine.base_key(object.hostname))&.key if object.pending?
    end
  end
end
