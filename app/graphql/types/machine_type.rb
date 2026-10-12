# frozen_string_literal: true

module Types
  class MachineType < Types::BaseObject
    grants "xixo:resources:read"

    description "What the xixo agent on a machine last said about it."

    field :hostname, String, description: "The name the machine gives itself."
    field :os, String
    field :arch, String
    field :version, String, description: "The version of the agent."
    field :connected, Boolean, null: false, description: "Whether the agent is connected to xixo now."
    field :seen_at, GraphQL::Types::ISO8601DateTime, description: "When the agent last said anything."
    field :folders, [ String ], null: false, description: "The folders the agent shares, as its own config lists them."
    field :uptime, Float, description: "Seconds since the machine started."
    field :load, [ Float ], null: false, description: "The load average over one, five, and fifteen minutes."
    field :memory_total, GraphQL::Types::BigInt
    field :memory_available, GraphQL::Types::BigInt
    field :disks, [ Types::MachineDiskType ], null: false
    field :extractors, [ String ], null: false,
          description: "The kinds of file the agent can read, by the programs installed on the machine."
    field :unread, [ String ], null: false,
          description: "The kinds of file the agent cannot read, because the machine lacks their programs. " \
                       "Such a file on this machine is not read unless the machine lends it to the server."
    field :lends, Boolean, null: false,
          description: "Whether a file this machine cannot read goes to the agent beside the server."
    field :warnings, [ String ], null: false,
          description: "What the agent last said is keeping it from working fully, such as a shared folder it " \
                       "may not read, each as a sentence to show a person."
    field :tools, [ String ], null: false,
          description: "The tools the machine offers to MCP clients through xixo, as its agent's config names them: " \
                       "browse, search, read, write, extract, and models."
    field :services, [ Types::MachineServiceType ], null: false,
          description: "Model servers listening on the machine, with its tailnet address when it has one."

    def hostname = object.machine["hostname"]
    def os = object.machine["os"]
    def arch = object.machine["arch"]
    def version = object.machine["version"]
    def connected = object.connected?
    def seen_at = object.seen_at
    def folders = object.offered_folders
    def uptime = health["uptime"]
    def load = Array(health["load"]).compact
    def memory_total = health.dig("memory", "total")
    def memory_available = health.dig("memory", "available")
    def disks = Array(health["disks"])
    def services = Array(object.machine["services"])
    def extractors = object.extractors
    def unread = Resource::XixoAgent::EXTRACTORS - object.extractors
    def lends = object.lends?
    def tools = object.offered_tools
    def warnings = object.warnings

    private

      def health
        object.machine["health"].to_h
      end
  end
end
