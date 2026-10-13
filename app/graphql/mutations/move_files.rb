# frozen_string_literal: true

module Mutations
  class MoveFiles < BaseMutation
    description "Moves files from folders on machines running xixo link into a folder on another one. Each file is " \
                "copied, both machines hash their copy, and the original is removed only when the hashes match. " \
                "Name a folder with sourceId and path, or a selection of files with feedIds, query, and type."

    argument :destination_id, ID, required: true, description: "The folder resource the files move into."
    argument :into, String, required: false, description: "A folder inside the destination. Left off, its top."
    argument :source_id, ID, required: false, description: "The folder resource to move a folder out of."
    argument :path, String, required: false,
             description: "A folder or a file inside the source. Left off, everything in the source moves."
    argument :feed_ids, [ ID ], required: false, description: "The files to move."
    argument :query, String, required: false, description: "Moves the files a search finds."
    argument :type, String, required: false, description: "Moves the files of one type."

    field :run, Types::RunType, null: false

    def resolve(destination_id:, into: nil, source_id: nil, path: nil, feed_ids: nil, query: nil, type: nil)
      destination = resource!(destination_id)
      source = resource!(source_id) if source_id.present?
      feeds = { "id" => feed_ids.presence, "query" => query.presence, "type" => type.presence }.compact

      run = Move.start!(grant: context[:grant], destination: destination, into: into, source: source, path: path,
                        feeds: feeds.presence)

      { run: run }
    rescue Resource::Refused, ArgumentError => e
      refused(e.message)
    end
  end
end
