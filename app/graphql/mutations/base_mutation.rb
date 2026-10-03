# frozen_string_literal: true

module Mutations
  class BaseMutation < GraphQL::Schema::RelayClassicMutation
    argument_class Types::BaseArgument
    field_class Types::BaseField
    input_object_class Types::BaseInputObject
    object_class Types::BaseObject

    private

      def feed!(id)
        Feed.find_by(id: id) || raise(GraphQL::ExecutionError, "no feed with id #{id}")
      end

      def resource!(id)
        Resource.visible_to(context[:grant]).find_by(id: id) ||
          raise(GraphQL::ExecutionError, "no resource with id #{id}")
      end

      def run!(id)
        Run.visible_to(context[:grant]).find_by(id: id) || raise(GraphQL::ExecutionError, "no run with id #{id}")
      end

      def refused(message)
        raise GraphQL::ExecutionError, message
      end
  end
end
