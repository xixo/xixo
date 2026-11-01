# frozen_string_literal: true

module Types
  class MachineType < Types::BaseObject
    grants "xixo:resources:read"

    description "What xixo link on a machine last said about it."

    field :hostname, String, description: "The name the machine gives itself."
    field :os, String
    field :arch, String
    field :system, String, description: "The system and its version it reported when it linked up, such as macOS 26.0."
    field :model, String, description: "The hardware model it reported when it linked up, such as MacBook Pro (16-inch, 2023)."
    field :kind, String, description: "What kind of machine it is: laptop, desktop, all-in-one, or server. Empty when it cannot tell."
    field :battery, Boolean, null: false, description: "Whether the machine has a battery."
    field :gpus, [ Types::MachineGpuType ], null: false, description: "The GPUs the machine reports."
    field :plan, [ Types::PlanLineType ], null: false,
          description: "What the machine does, as xixo plans it from the machine's description: catalog, extract, " \
                       "and models. An administrator turns a line off with setMachinePlan."
    field :version, String, description: "The version of xixo link."
    field :release, String, description: "The version of xixo link this xixo ships."
    field :current, Boolean,
          description: "Whether xixo link runs the build this xixo ships. Empty when xixo ships none for the machine's " \
                       "system and processor, and when xixo link is older than updates and does not say which build it " \
                       "runs."
    field :updates, Boolean, null: false,
          description: "Whether xixo updates xixo link on the machine to the build it ships. An administrator pauses " \
                       "and resumes it with requestMachineUpdate."
    field :protocol, Integer, null: false,
          description: "The protocol xixo link speaks. xixo accepts the protocol it speaks and the one before. A link " \
                       "from before protocols speaks 0."
    field :serial, GraphQL::Types::BigInt, description: "The serial of the release xixo link runs, when it knows it."
    field :update_state, String, null: false,
          description: "Where the machine stands with updates: server for the link beside the server, manual, paused, " \
                       "ahead (newer than xixo allows, and asked to go back), waiting_for_xixo (newer, with no release " \
                       "to go back to), current, unknown, updating, held, waiting, or offline."
    field :last_updated_at, GraphQL::Types::ISO8601DateTime, description: "When xixo link last arrived on a release xixo offered."
    field :last_rollback, String, description: "What went wrong the last time xixo link could not update, as a sentence."
    field :last_rollback_at, String, description: "When that was."
    field :updates_itself, Boolean, null: false,
          description: "Whether xixo link on the machine can update itself. It cannot when it runs in a container, which " \
                       "updates with its image, or when it was installed before xixo link updated itself."
    field :connected, Boolean, null: false, description: "Whether xixo link is connected to xixo now."
    field :seen_at, GraphQL::Types::ISO8601DateTime, description: "When xixo link last said anything."
    field :folders, [ String ], null: false, description: "The folders xixo link shares, as its own config lists them."
    field :writable, [ String ], null: false,
          description: "The shared folders xixo may write into. A folder is writable when the link-up command named " \
                       "it with :rw and the machine's config allows the write tool."
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
    field :held_back, [ String ], null: false,
          description: "What the machine's own config keeps off. Today that is lend, when the config sets it to false."
    field :lends, Boolean, null: false,
          description: "Whether the bytes of its files may leave the machine: to be opened or downloaded, and to " \
                       "be read by another machine when it lacks the program itself. It is on unless the " \
                       "machine's config sets lend to false."
    field :warnings, [ String ], null: false,
          description: "What xixo link last said is keeping it from working fully, such as a shared folder it " \
                       "may not read, each as a sentence to show a person."
    field :tools, [ String ], null: false,
          description: "The tools the machine offers to MCP clients through xixo: browse, search, read, extract, " \
                       "write when it shares a folder writable, and models when its plan runs them."
    field :waiting, [ Types::WaitingFilesType ], null: false,
          description: "Files on this machine whose reading waits for it, by kind: it is offline, or it lacks " \
                       "their program and lends none of its files."
    field :linked, Boolean, null: false,
          description: "Whether xixo link is enrolled as this machine, whether or not it is connected now."
    field :services, [ Types::MachineServiceType ], null: false,
          description: "Model servers xixo link found listening on the machine."
    field :parts, [ Types::MachinePartType ], null: false,
          description: "The parts xixo link runs on the machine, with each one's state. The models part runs Ollama " \
                       "when the plan runs models and no model server was found."

    def hostname = object.machine["hostname"]
    def os = object.machine["os"]
    def arch = object.machine["arch"]
    def system = object.about["system"]
    def model = object.about["model"]
    def kind = object.about["kind"]
    def version = object.machine["version"]
    def release = object.release
    def current = object.current?
    def updates = object.updates?
    def protocol = object.protocol
    def serial = object.serial
    def update_state = object.update_state
    def last_updated_at = object.last_updated_at
    def last_rollback = object.last_rollback&.then { |held| "xixo link could not update to #{held['version']}: #{held['error']}" }
    def last_rollback_at = object.last_rollback&.dig("at")
    def updates_itself = object.updates_itself?
    def connected = object.connected?
    def seen_at = object.seen_at
    def folders = object.offered_folders
    def writable = object.writable_folders
    def uptime = health["uptime"]
    def load = Array(health["load"]).compact
    def memory_total = health.dig("memory", "total")
    def memory_available = health.dig("memory", "available")
    def disks = Array(health["disks"])
    def services = Array(object.machine["services"])
    def parts = object.parts
    def gpus = Array(object.about["gpus"])
    def battery = object.about["battery"] == true
    def plan = object.plan.map(&:to_h)
    def extractors = object.extractors
    def unread = Resource::Machine::EXTRACTORS - object.extractors
    def lends = object.lends?
    def tools = object.offered_tools
    def warnings = object.warnings
    def waiting = Types::WaitingFilesType.on(context, object.id)
    def linked = object.client_id.present?
    def held_back = object.held_back

    private

      def health
        object.machine["health"].to_h
      end
  end
end
