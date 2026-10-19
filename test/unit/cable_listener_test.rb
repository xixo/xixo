require "test_helper"

class CableListenerTest < ActiveSupport::TestCase
  class Flaky
    attr_reader :tries, :paused

    def initialize(failing)
      @failing = failing
      @tries = 0
      @paused = []
    end

    def listen
      @tries += 1
      raise ActiveRecord::ConnectionNotEstablished, "gone" if @tries <= @failing

      :listening
    end

    def sleep(seconds)
      @paused << seconds
    end

    prepend CableListenerKeepsListening
  end

  test "the listener goes back to listening after its database connection fails, pausing longer each time" do
    held = Flaky.new(7)

    assert_equal :listening, held.listen
    assert_equal 8, held.tries
    assert_equal [ 1, 2, 4, 8, 16, 30, 30 ], held.paused
  end

  test "the production listener carries the module" do
    assert_includes ActionCable::SubscriptionAdapter::SolidCable::Listener.ancestors, CableListenerKeepsListening
  end
end
