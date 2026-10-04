require "test_helper"

class FeedLifetimeTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "life-#{SecureRandom.hex(4)}", name: "Lifetimes")
    @other = Tenant.create!(subdomain: "life-#{SecureRandom.hex(4)}", name: "Elsewhere")
  end

  teardown do
    Current.grant = nil
    Current.confined_to = nil
  end

  test "what an agent makes while answering a question lasts thirty days unless it says otherwise" do
    Tenant.switch(@tenant) do
      answering!

      default = created(title: "Toronto weather today")
      forever = created(title: "Open-Meteo API", lasts: "forever")
      week = created(title: "This week's forecast", lasts: "7")

      assert_in_delta Feed::KEPT_FOR.from_now, Time.zone.parse(default[:expires_at].to_s), 5
      assert_nil forever[:expires_at]
      assert_in_delta 7.days.from_now, Time.zone.parse(week[:expires_at].to_s), 5
    end
  end

  test "what someone makes through a tool outside a question lasts forever unless they say otherwise" do
    Tenant.switch(@tenant) do
      Current.grant = grant

      assert_nil created(title: "A note of my own")[:expires_at]
      assert_not_nil created(title: "A reminder", lasts: "2")[:expires_at]
    end
  end

  test "a lifetime is forever or a number of days, and nothing else" do
    Tenant.switch(@tenant) do
      Current.grant = grant

      reply = Tool::Feeds.call(server_context: {}, do: "create", type: "xixo:note", title: "Odd", lasts: "a while")

      assert reply.error?
      assert_match(/forever or a number of days/, reply.content.first[:text])
    end
  end

  test "an agent can make what it kept last forever, but only what it made" do
    Tenant.switch(@tenant) do
      answering!
      made = created(title: "Kept by the run")
      theirs = Feed.create!(type: Feed::NOTE, key: "Somebody's", title: "Somebody's", expires_at: 3.days.from_now)

      lasted = Tool::Feeds.call(server_context: {}, do: "last", id: made[:id], lasts: "forever")
      refused = Tool::Feeds.call(server_context: {}, do: "last", id: theirs.id.to_s, lasts: "forever")

      assert_not lasted.error?
      assert_nil Feed.find(made[:id]).expires_at
      assert refused.error?
      assert_not_nil theirs.reload.expires_at
    end
  end

  test "an object kept while answering lasts thirty days, and keeping it again leaves its lifetime alone" do
    Tenant.switch(@tenant) do
      bucket = Resource::S3.create!(key: "bucket", details: { "endpoint" => FakeS3::ENDPOINT },
                                    credentials: { "access_key_id" => "id", "secret_access_key" => "secret" })
      bucket.client.put_object(bucket: "bucket", key: "forecast.json", body: %({"temperature":19.2}))
      bucket.client.put_object(bucket: "bucket", key: "manual.txt", body: "how the API works")
      answering!

      forecast = kept("forecast.json")
      manual = kept("manual.txt", lasts: "forever")

      assert_in_delta Feed::KEPT_FOR.from_now, Time.zone.parse(forecast["expires_at"].to_s), 5
      assert_nil manual["expires_at"]

      Feed.find(forecast["id"]).update!(expires_at: 2.days.from_now)
      again = kept("forecast.json")

      assert_in_delta 2.days.from_now, Time.zone.parse(again["expires_at"].to_s), 5
    end
  end

  test "expired feeds are forgotten in every tenant, and the rest are left" do
    gone = Tenant.switch(@tenant) { Feed.create!(type: Feed::NOTE, key: "Stale", title: "Stale", expires_at: 1.minute.ago) }
    kept = Tenant.switch(@tenant) { Feed.create!(type: Feed::NOTE, key: "Fresh", title: "Fresh", expires_at: 1.day.from_now) }
    forever = Tenant.switch(@tenant) { Feed.create!(type: Feed::NOTE, key: "Forever", title: "Forever") }
    theirs = Tenant.switch(@other) { Feed.create!(type: Feed::NOTE, key: "Theirs", title: "Theirs", expires_at: 1.hour.ago) }

    ForgetExpiredJob.perform_now

    Tenant.switch(@tenant) do
      assert_nil Feed.find_by(id: gone.id)
      assert Feed.exists?(kept.id)
      assert Feed.exists?(forever.id)
      assert_equal "Stale", AuditEvent.find_by!(action: "forget_expired_feed").arguments["title"]
    end
    Tenant.switch(@other) { assert_nil Feed.find_by(id: theirs.id) }
  end

  private

    def grant
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))
    end

    def answering!
      Current.grant = grant
      Current.confined_to = Concurrent::Set.new
    end

    def kept(key, lasts: nil)
      reply = Tool::Resources.call(server_context: {}, key: "bucket", do: "keep", input: { "key" => key, "lasts" => lasts }.compact)
      raise reply.content.first[:text] if reply.error?

      JSON.parse(reply.content.first[:text])
    end

    def created(title:, lasts: nil)
      reply = Tool::Feeds.call(server_context: {}, do: "create", type: "xixo:note", title: title, lasts: lasts)
      raise reply.content.first[:text] if reply.error?

      JSON.parse(reply.content.first[:text], symbolize_names: true)
    end
end
