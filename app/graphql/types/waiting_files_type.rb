# frozen_string_literal: true

module Types
  class WaitingFilesType < Types::BaseObject
    grants "xixo:resources:read"

    description "Files whose reading is parked until a machine that can read them links up."

    field :kind, String, hash_key: "kind",
          description: "The kind of file they are, by the extractor that reads them: pdf, image, media, and so on. " \
                       "Empty for files any extractor will do for."
    field :count, Integer, null: false, hash_key: "count"

    def self.on(context, machine_id)
      context[:parked] ||= Analysis.parked.readable_by(context[:grant]).group(:waits_on_id, :waits_for).count

      context[:parked].filter_map { |(on, kind), count| { "kind" => kind, "count" => count } if on == machine_id }
                      .sort_by { |held| [ -held["count"], held["kind"].to_s ] }
    end
  end
end
