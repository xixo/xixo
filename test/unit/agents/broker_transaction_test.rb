require "test_helper"
require_relative "../../support/machines"

class BrokerTransactionTest < ActiveSupport::TestCase
  include Machines

  self.use_transactional_tests = false

  setup do
    @tenant = Tenant.create!(subdomain: "broker-#{SecureRandom.hex(4)}", name: "Broker")
    @agent = agent_on(@tenant)
  end

  teardown do
    Tenant.switch(@tenant) do
      AgentExchange.delete_all
      Resource.delete_all
    end
    @tenant.destroy!
  end

  test "a question asked inside an open transaction reaches an agent answering on another connection" do
    answering = replying { |exchange| exchange.answer!("entries" => []) }

    answered = Tenant.switch(@tenant) do
      ActiveRecord::Base.transaction { Resource::XixoAgent.find(@agent.id).ask("list", { "folder" => "/srv/media" }, within: 5.seconds) }
    end

    assert_equal({ "entries" => [] }, answered)
  ensure
    answering&.join(5)
  end

  test "an upload staged inside an open transaction can be taken on another connection" do
    staged = Tenant.switch(@tenant) do
      ActiveRecord::Base.transaction { Resource::XixoAgent.find(@agent.id).upload(StringIO.new("held bytes")) }
    end

    taken = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Tenant.switch(@tenant) { AgentExchange.taken!(Resource::XixoAgent.find(@agent.id), staged["upload"])&.received }
      end
    end.value

    assert_equal 10, taken
  end

  private

    def replying
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Tenant.switch(@tenant) do
            exchange = nil
            50.times do
              exchange = AgentExchange.asked.find_by(resource_id: @agent.id)
              break if exchange

              sleep 0.1
            end

            yield exchange if exchange
          end
        end
      end
    end
end
