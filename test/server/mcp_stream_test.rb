require "test_helper"

class McpStreamTest < ActiveSupport::TestCase
  setup do
    response = ActionController::Live::Response.new
    response.request = ActionDispatch::TestRequest.create
    @buffer = response.stream
    @stream = McpController::Stream.new(@buffer)
  end

  test "a frame written through it reaches the response" do
    @stream.write("data: {}\n\n")
    @stream.flush
    @stream.close

    assert_equal "data: {}\n\n", @buffer.body
  end

  test "flush on a closed stream raises the error the transport treats as a dropped peer" do
    @stream.close

    assert_predicate @stream, :closed?
    assert_raises(IOError) { @stream.flush }
  end

  test "a client that went away surfaces as an IOError, so the transport frees its slot quietly" do
    @buffer.abort

    assert_raises(IOError) { @stream.write("data: {}\n\n") }
  end
end
