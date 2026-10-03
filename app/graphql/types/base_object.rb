# frozen_string_literal: true

module Types
  class BaseObject < GraphQL::Schema::Object
    field_class Types::BaseField

    class << self
      def grants(*scopes)
        @grants = scopes.flatten.map(&:to_s) if scopes.any?
        @grants || []
      end

      def authorized?(object, context)
        return false unless super
        return true if grants.empty?

        grant = context[:grant]

        grant.present? && grants.any? { |scope| grant.permits?(scope) }
      end
    end
  end
end
