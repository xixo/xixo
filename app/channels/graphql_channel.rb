class GraphqlChannel < ApplicationCable::Channel
  def subscribed
    @subscription_ids = []
  end

  def execute(data)
    result = Tenant.switch(tenant) do
      XixoSchema.execute(
        data["query"],
        context: { channel: self, tenant: tenant, tenant_id: tenant.id, grant: grant },
        variables: ensure_hash(data["variables"]),
        operation_name: data["operationName"]
      )
    end

    @subscription_ids << result.context[:subscription_id] if result.context[:subscription_id]

    transmit({ result: result.to_h, more: result.subscription? })
  end

  def unsubscribed
    @subscription_ids.each { |sid| XixoSchema.subscriptions.delete_subscription(sid) }
  end

  private

    def ensure_hash(ambiguous_param)
      case ambiguous_param
      when String
        ambiguous_param.present? ? ensure_hash(JSON.parse(ambiguous_param)) : {}
      when Hash, ActionController::Parameters
        ambiguous_param
      when nil
        {}
      else
        raise ArgumentError, "Unexpected parameter: #{ambiguous_param}"
      end
    end
end
