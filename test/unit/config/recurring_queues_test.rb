require "test_helper"

class RecurringQueuesTest < ActiveSupport::TestCase
  test "every recurring task in production lands in a queue a worker reads when masks is not embedded" do
    processes = EmbeddedIssuer.method(:processes)
    EmbeddedIssuer.define_singleton_method(:processes) { 0 }

    served = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))
      .fetch("production").fetch("workers")
      .select { |worker| worker["processes"].to_i.positive? }
      .flat_map { |worker| Array(worker["queues"]) }

    Rails.application.config_for(:recurring, env: "production").each do |key, task|
      assert_includes served, task.fetch(:queue, "solid_queue_recurring").to_s, key
    end
  ensure
    EmbeddedIssuer.define_singleton_method(:processes, processes)
  end
end
