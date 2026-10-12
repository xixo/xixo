# frozen_string_literal: true

module Types
  class SetupType < Types::BaseObject
    field :storage, Boolean, null: false, description: "Whether drops and uploads have a default place to land."
    field :inference, Boolean, null: false, description: "Whether a model server that answers is attached for everyone."
    field :client, Boolean, null: false, description: "Whether an MCP client has called a tool yet."
    field :storage_resource, Types::SetupResourceType,
          description: "The resource drops and uploads land in. Empty until one is the default."
    field :inference_resource, Types::SetupResourceType,
          description: "The model server that answers questions, even while it is failing its check, so a " \
                       "checklist can point at it. Empty until one is attached for everyone."
    field :connected_client, Types::SetupClientType,
          description: "The MCP client that called a tool most recently. Empty until one has."

    def storage
      storage_resource.present?
    end

    def inference
      inference_resource.present? && !inference_resource.down?
    end

    def client
      connected_client.present?
    end

    def storage_resource
      return @storage_resource if defined?(@storage_resource)

      @storage_resource = Resource.default_storage
    end

    def inference_resource
      return @inference_resource if defined?(@inference_resource)

      @inference_resource = Resource.best_inference { true }
    end

    def connected_client
      return @connected_client if defined?(@connected_client)

      @connected_client = AuditEvent.where(channel: "mcp", actor: %w[person client]).newest_first.first
    end
  end
end
