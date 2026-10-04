require "test_helper"

class SwitchTest < ActiveSupport::TestCase
  NAME = "XIXO_SWITCH_UNDER_TEST".freeze

  teardown { ENV.delete(NAME) }

  test "an unset or empty switch takes its default" do
    assert_not Switch.on?(NAME)
    assert Switch.on?(NAME, default: true)

    ENV[NAME] = " "

    assert Switch.on?(NAME, default: true)
  end

  test "the words for on turn it on, in any case" do
    %w[1 true TRUE yes on].each do |value|
      ENV[NAME] = value

      assert Switch.on?(NAME, default: false), "#{value} should turn it on"
    end
  end

  test "the words for off turn it off, even where the default is on" do
    %w[0 false False no off].each do |value|
      ENV[NAME] = value

      assert_not Switch.on?(NAME, default: true), "#{value} should turn it off"
    end
  end

  test "anything else is refused with the variable's name" do
    ENV[NAME] = "maybe"

    error = assert_raises(Switch::Invalid) { Switch.on?(NAME) }

    assert_match NAME, error.message
  end
end
