# frozen_string_literal: true

module Types
  class ServerUpdaterType < Types::BaseObject
    grants "xixo:settings:read"

    description "The xixo-updater that runs beside this server, and the newest build of it CI signed. The updater does not update itself."

    field :version, String, hash_key: "version", description: "The version the running updater names, such as 0.6.1+ca2c19b."
    field :newest, String, hash_key: "newest", description: "The newest signed build on the channel: a release on releases, or the commit on main."
    field :newest_revision, String, hash_key: "newest_revision", description: "The commit the newest build came from."
    field :newest_created, String, hash_key: "newest_created", description: "When CI built the newest build."
    field :behind, Boolean, null: false, description: "Whether the newest build is newer than the one running, so an operator moves the updater's image tag."

    def behind = object["behind"] == true
  end
end
