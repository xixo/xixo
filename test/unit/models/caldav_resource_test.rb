require "test_helper"
require_relative "../../support/fake_dav_server"

class CaldavResourceTest < ActiveSupport::TestCase
  EVENT = <<~'ICS'.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:pelicans-1
    DTSTART:20270830T120000Z
    SUMMARY:Lunch with the pelicans\, then the tide tables\; briefly
    LOCATION:1 Mudflat Lane
    END:VEVENT
    END:VCALENDAR
  ICS

  setup do
    SearchIndex.reset!

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeDavServer.current
    @server.reset!
    @server.put "calendar/lunch.ics", EVENT, type: "text/calendar; charset=utf-8"
    @server.put "calendar/notes.txt", "not an event"

    @tenant = Tenant.create!(subdomain: "cal-#{SecureRandom.hex(4)}", name: "Calendars")

    Tenant.switch(@tenant) do
      @resource = Resource::Caldav.create!(
        key: "cal-#{SecureRandom.hex(4)}",
        name: "Calendar",
        details: { "url" => @server.url },
        credentials: { "username" => "someone", "password" => "irrelevant" }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "only calendar objects are catalogued, and they are calendars" do
    sync

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal "text/calendar", Feed.first.mime
      assert_equal "calendar/lunch.ics", Reference.first.locator_key
    end
  end

  test "the calendar analyzer reads it without knowing where it came from" do
    sync

    Tenant.switch(@tenant) do
      item = Feed.first
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, item.id) }

      analysis = item.reload.analysis.steps

      assert_includes analysis.dig("text", "result"), "Lunch with the pelicans"
    end
  end

  test "an escaped comma or semicolon survives unescaping" do
    sync

    Tenant.switch(@tenant) do
      item = Feed.first
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, item.id) }

      summary = item.reload.analysis.steps.dig("events", "result").first["summary"]

      assert_equal "Lunch with the pelicans, then the tide tables; briefly", summary
    end
  end

  test "a calendar is read-only and cannot be an export destination" do
    assert_not @resource.storage?
    assert_raises(ArgumentError) { @resource.storage! }
    assert_not @resource.class.command_schema.key?(:put)
  end

  test "it inherits the webdav walk, so a nested calendar is still found" do
    @server.put "shared/team/standup.ics", EVENT, type: "text/calendar"

    sync

    Tenant.switch(@tenant) do
      assert_equal %w[calendar/lunch.ics shared/team/standup.ics], Reference.pluck(:locator_key).sort
    end
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end
end
