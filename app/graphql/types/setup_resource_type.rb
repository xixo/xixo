# frozen_string_literal: true

module Types
  class SetupResourceType < Types::BaseObject
    KINDS = { "s3" => "object storage", "webdav" => "a WebDAV share", "database" => "the catalog's own database",
              "openai-compatible" => "a model server" }.freeze

    field :id, ID, null: false
    field :key, String, null: false
    field :name, String
    field :type, String, null: false, method: :type
    field :kind, String, null: false,
          description: "What it is, in a few words, such as a folder on this server."
    field :model, String,
          description: "The model that answers questions, for a model server that declares one."
    field :down, Boolean, null: false, method: :down?,
          description: "Whether it failed its last check, is offline, or needs connecting again."

    def kind
      return folder if object.is_a?(Resource::Filesystem)

      KINDS.fetch(object.type) { label }
    end

    def model
      return unless object.respond_to?(:model_for)

      object.model_for(Resource::OpenaiCompatible::AGENT_ROLE)
    rescue Resource::Unusable
      nil
    end

    private

      def folder
        agent = object.agent
        return "a folder" if agent.nil?
        return "a folder on this server" if agent.local?

        "a folder on #{agent.machine['hostname'].presence || agent.name.presence || agent.key}"
      end

      def label
        held = object.class.attaching&.dig(:label).to_s
        held.sub(/\A(An?) /) { "#{::Regexp.last_match(1).downcase} " }.presence || object.type
      end
  end
end
