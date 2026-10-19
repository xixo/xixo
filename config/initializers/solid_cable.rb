require "action_cable/subscription_adapter/solid_cable"

module CableListenerKeepsListening
  LONGEST_PAUSE = 30

  def listen
    failures = 0

    begin
      super
    rescue StandardError => e
      failures += 1
      pause = [ 2**[ failures - 1, 5 ].min, LONGEST_PAUSE ].min
      Rails.logger.error("the cable listener stopped on #{e.class}: #{e.message}. It listens again in #{pause} seconds")
      sleep(pause)
      retry
    end
  end
end

ActionCable::SubscriptionAdapter::SolidCable::Listener.prepend(CableListenerKeepsListening)
