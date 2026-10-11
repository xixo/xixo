# frozen_string_literal: true

module Types
  class SetupType < Types::BaseObject
    field :storage, Boolean, null: false, description: "Whether drops and uploads have a default place to land."
    field :inference, Boolean, null: false, description: "Whether a model server that answers is attached for everyone."
    field :client, Boolean, null: false, description: "Whether an MCP client has called a tool yet."

    def storage
      Resource.default_storage.present?
    end

    def inference
      model = Resource.best_inference { true }
      model.present? && !model.down?
    end

    def client
      AuditEvent.where(channel: "mcp", actor: %w[person client]).exists?
    end
  end
end
