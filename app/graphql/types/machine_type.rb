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

    private

      def health
        object.machine["health"].to_h
      end
  end
end
