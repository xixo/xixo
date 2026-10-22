# frozen_string_literal: true

module Types
  class ServerUpdateEventType < Types::BaseObject
    grants "xixo:settings:read"

    description "Something the updater did or refused: a check, pull, swap, rollback, refusal, or request."

    field :at, String, null: false, hash_key: "at", description: "When it happened."
    field :action, String, null: false, hash_key: "action",
          description: "check, pull, swap, watch, rollback, refuse, or the request it took: update_now, pause, resume, roll_back, or channel."
    field :kind, String, hash_key: "kind", description: "The image it concerned: xixo, xixo-link, or masks."
    field :digest, String, hash_key: "digest", description: "The digest of the build it concerned."
    field :error, String, hash_key: "error", description: "What went wrong, when it failed or was refused."
    field :by, String, hash_key: "by", description: "Who asked, for a request."
    field :channel, String, hash_key: "channel", description: "The channel chosen, for a channel request."
  end
end
