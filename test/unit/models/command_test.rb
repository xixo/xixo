require "test_helper"

class CommandTest < ActiveSupport::TestCase
  test "a command that runs past its time is stopped with everything it started" do
    marker = Rails.root.join("tmp", "command-#{SecureRandom.hex(4)}")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Command::Stopped) do
      Command.capture("sh", "-c", "(sleep 3; touch #{marker}) & sleep 30", seconds: 1)
    end

    assert_match(/sh ran past 1 seconds and was stopped/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    sleep 3
    assert_not File.exist?(marker), "the child it started was stopped too"
  ensure
    FileUtils.rm_f(marker)
  end

  test "a command that asks for more memory than it is allowed fails instead of taking it" do
    _out, _err, status = Command.capture("ruby", "-e", "'x' * 600_000_000", memory: 256.megabytes)

    assert_not status.success?
  end

  test "a command within its limits answers as capture3 does" do
    out, err, status = Command.capture("sh", "-c", "printf held; printf said >&2")

    assert status.success?
    assert_equal "held", out
    assert_equal "said", err
  end
end
