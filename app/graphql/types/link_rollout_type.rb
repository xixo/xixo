# frozen_string_literal: true

module Types
  class LinkRolloutType < Types::BaseObject
    grants "xixo:settings:read"

    description "How the release of xixo link this xixo ships reaches the machines: the server first, then one " \
                "machine per platform, then everyone."

    field :release, String, null: false, description: "The SHA-256 of the release description, release.json."
    field :version, String, description: "The version the release carries."
    field :serial, GraphQL::Types::BigInt, description: "The release's serial, which only rises."
    field :phase, String, null: false,
          description: "waiting_for_server, first, everyone, done, held, or paused. A rollout waits until the server " \
                       "has been healthy for 15 minutes, updates one machine per platform and watches it for 30 " \
                       "minutes, then offers the release to every machine. It is held when a first machine rolls back."
    field :started_at, GraphQL::Types::ISO8601DateTime, null: false, description: "When xixo first shipped this release."
    field :phase_at, GraphQL::Types::ISO8601DateTime, null: false, description: "When the current phase began."
    field :held_reason, String, description: "Why the rollout stopped, when it is held."
    field :first_machines, [ Types::LinkFirstMachineType ], null: false,
          description: "The machine that updates first on each platform, and when it arrived on the release."
    field :server_healthy_for, Integer, null: false, description: "How many seconds the server must be healthy before the first machine updates."
    field :first_healthy_for, Integer, null: false, description: "How many seconds a first machine must stay connected before everyone follows."

    def first_machines = object.first_machine_entries
    def server_healthy_for = LinkRollout::SERVER_HEALTHY_FOR.to_i
    def first_healthy_for = LinkRollout::FIRST_HEALTHY_FOR.to_i
  end
end
