require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  setup do
    SolidQueue::Process.delete_all
    SolidQueue::Job.delete_all
  end

  teardown do
    SolidQueue::Process.delete_all
    SolidQueue::Job.delete_all
  end

  test "up is ok when the database and search answer, the queue is moving, and a worker is beating" do
    beating

    get "/up", headers: { "HOST" => "anything.example.test" }

    assert_response :ok
    assert_equal({ "status" => "ok", "checks" => { "database" => "ok", "search" => "ok", "queue" => "ok", "worker" => "ok" } },
                 response.parsed_body)
  end

  test "up fails when search does not answer, or answers red" do
    beating

    [ nil, "red" ].each do |status|
      SearchIndex.client.status = status
      get "/up"

      assert_response :service_unavailable
      assert_equal "failing", response.parsed_body["status"]
      assert_equal "failing", response.parsed_body.dig("checks", "search")
    ensure
      SearchIndex.client.status = "yellow"
    end
  end

  test "a quiet worker or a late queue is reported without failing up" do
    SolidQueue::Process.create!(kind: "Worker", name: "worker-quiet", pid: 1, hostname: "elsewhere",
                                last_heartbeat_at: 10.minutes.ago)
    job = SolidQueue::Job.create!(queue_name: "default", class_name: "SyncResourceJob", arguments: {}, created_at: 20.minutes.ago)
    SolidQueue::ReadyExecution.where(job: job).update_all(created_at: 20.minutes.ago)

    get "/up"

    assert_response :ok
    assert_equal({ "database" => "ok", "search" => "ok", "queue" => "failing", "worker" => "failing" },
                 response.parsed_body["checks"])
  end

  private

    def beating
      SolidQueue::Process.create!(kind: "Worker", name: "worker-beating", pid: 1, hostname: "here", last_heartbeat_at: Time.current)
    end
end
