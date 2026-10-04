# frozen_string_literal: true

class GraphqlController < ApplicationController
  include Granted

  def execute
    result = XixoSchema.execute(
      params[:query],
      variables: prepare_variables(params[:variables]),
      operation_name: params[:operationName],
      context: {
        tenant: current_tenant,
        tenant_id: current_tenant.id,
        grant: grant
      }
    )

    render json: result
  rescue StandardError => e
    raise e unless Rails.env.development?

    handle_error_in_development(e)
  end

  private

    def prepare_variables(variables_param)
      case variables_param
      when String
        variables_param.present? ? (JSON.parse(variables_param) || {}) : {}
      when Hash
        variables_param
      when ActionController::Parameters
        variables_param.to_unsafe_hash
      when nil
        {}
      else
        raise ArgumentError, "Unexpected parameter: #{variables_param}"
      end
    end

    def handle_error_in_development(e)
      logger.error e.message
      logger.error e.backtrace.join("\n")

      render json: { errors: [ { message: e.message, backtrace: e.backtrace } ], data: {} },
             status: 500
    end
end
