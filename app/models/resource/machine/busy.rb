class Resource
  class Machine
    module Busy
      SLACK = 30.seconds

      module_function

      def hold(machine, grant, within:)
        taken = []

        held_keys(machine, grant).each do |key, told|
          raise Resource::Failed, told unless take(key, within + SLACK)

          taken << key
        end

        yield
      ensure
        taken.each { |key| Rails.cache.decrement(key) }
      end

      def held_keys(machine, grant)
        speaking = grant&.speaks_for.presence

        {
          "machine-busy:#{machine.id}" => "#{machine.key} is busy with another long call. Try again once it answers",
          ("machine-caller-busy:#{machine.tenant_id}:#{speaking}" if speaking) =>
            "a long call to a machine is already waiting on an answer for you. Try again once it answers"
        }.compact
      end

      def take(key, lasts)
        held = Rails.cache.increment(key, 1, expires_in: lasts)
        return true if held.nil? || held <= 1

        Rails.cache.decrement(key)
        false
      end
    end
  end
end
