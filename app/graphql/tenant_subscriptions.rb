# frozen_string_literal: true

class TenantSubscriptions < GraphQL::Subscriptions::ActionCableSubscriptions
  def execute_update(subscription_id, event, object)
    Tenant.switch(event.context[:tenant]) { super }
  end

  private

    def load_action_cable_message(message, context)
      Tenant.switch(context[:tenant]) { super }
    end
end
