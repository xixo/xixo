# frozen_string_literal: true

module Types
  class MachineType < Types::BaseObject
    grants "xixo:resources:read"

    description "What xixo link on a machine last said about it."

    field :hostname, String, description: "The name the machine gives itself."
    field :os, String
    field :arch, String
    field :version, String, description: "The version of xixo link."
    field :connected, Boolean, null: false, description: "Whether xixo link is connected to xixo now."
    field :seen_at, GraphQL::Types::ISO8601DateTime, description: "When xixo link last said anything."
    field :folders, [ String ], null: false, description: "The folders xixo link shares, as its own config lists them."
    field :uptime, Float, description: "Seconds since the machine started."
    field :load, [ Float ], null: false, description: "The load average over one, five, and fifteen minutes."
    field :memory_total, GraphQL::Types::BigInt
    field :memory_available, GraphQL::Types::BigInt
    field :disks, [ Types::MachineDiskType ], null: false
    field :extractors, [ String ], null: false,
          description: "The kinds of file xixo link can read, by the programs installed on the machine."
    field :unread, [ String ], null: false,
          description: "The kinds of file xixo link cannot read, because the machine lacks their programs. " \
                       "Such a file on this machine is read by a machine that reads for others when this one lends " \
                       "its files, and otherwise waits until this one can read it."
    field :lends, Boolean, null: false,
          description: "Whether xixo link on it lets the bytes of its files leave the machine: to be opened or " \
                       "downloaded, and to be read by another machine when it lacks the program itself."
    field :warnings, [ String ], null: false,
          description: "What xixo link last said is keeping it from working fully, such as a shared folder it " \
                       "may not read, each as a sentence to show a person."
    field :tools, [ String ], null: false,
          description: "The tools the machine offers to MCP clients through xixo, as its config names them: " \
                       "browse, search, read, write, extract, and models."
    field :extracts_for_others, Boolean,
          description: "Whether the machine's own config lets it read files from other places for xixo: uploads, " \
                       "mail attachments, cloud files, web pages, and files other machines lend. Empty when xixo " \
                       "link on it does not say."
    field :waiting, [ Types::WaitingFilesType ], null: false,
          description: "Files on this machine whose reading waits for it, by kind: it is offline, or it lacks " \
                       "their program and lends none of its files."
    field :linked, Boolean, null: false,
          description: "Whether xixo link is enrolled as this machine, whether or not it is connected now."
    field :self_linked, Boolean, null: false,
          description: "Whether the machine installed xixo link itself, with a code, instead of xixo installing it over SSH."
    field :linking_until, GraphQL::Types::ISO8601DateTime,
          description: "When the code handed out to link the machine stops working. Empty when none is waiting."
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
    def services
      Array(object.machine["services"]).map do |service|
        url = object.reached_at(service)

        service.merge("url" => url, "via" => (tailnet if url))
      end
    end
    def extractors = object.extractors
    def unread = Resource::Machine::EXTRACTORS - object.extractors
    def lends = object.lends?
    def tools = object.offered_tools
    def warnings = object.warnings
    def extracts_for_others = object.extracts_for_others
    def waiting = Types::WaitingFilesType.on(context, object.id)
    def linked = object.client_id.present?
    def self_linked = object.self_linked?
    def linking_until = object.link_expires_at

    private

      def tailnet
        return object.via.key if object.via_id && object.via.is_a?(Resource::Tailnet)

        context[:tailnet] = Resource::Tailnet.visible_to(context[:grant]).order(:key).pick(:key).to_s unless context.key?(:tailnet)
        context[:tailnet].presence
      end

      def health
        object.machine["health"].to_h
      end
  end
end
