require "test_helper"

class ProbeJob < ApplicationJob
  cattr_accessor :performed_in

  def perform = self.class.performed_in = Current.tenant&.subdomain
end

class SweepJob < ApplicationJob
  across_tenants!

  cattr_accessor :performed_in

  def perform = self.class.performed_in = Current.tenant&.subdomain
end

class TenantSwitchingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "demo-#{SecureRandom.hex(4)}", name: "Demo")
    @other = Tenant.create!(subdomain: "acme-#{SecureRandom.hex(4)}", name: "Acme")
  end

  def within(tenant = @tenant, &block) = Tenant.switch(tenant, &block)

  test "rows created under one tenant are invisible to another" do
    within(@tenant) { Feed.create!(type: Feed::FILE, key: "Demo invoice", title: "Demo invoice") }

    within(@other) do
      assert_equal 0, Feed.files.count
      assert_equal 0, Feed.unscoped.count,
                   "the database, not the default scope, must be what isolates tenants"
    end
  end

  test "switching to the tenant already current still isolates a connection that never entered it" do
    fresh = ActiveRecord::Base.connection_pool.send(:new_connection)
    setting = -> { fresh.select_value("SELECT current_setting('#{TenantIsolation::SETTING}', true)").to_s }

    within(@tenant) do
      Tenant.singleton_class.alias_method(:shared_connection, :connection)
      Tenant.define_singleton_method(:connection) { fresh }

      assert_equal "", setting.call, "a connection another thread checked out knows no tenant"

      Tenant.switch(@tenant) { assert_equal @tenant.id.to_s, setting.call }

      assert_equal "", setting.call, "and it goes back to the pool knowing none"
      assert_equal @tenant, Current.tenant
    ensure
      Tenant.singleton_class.alias_method(:connection, :shared_connection)
    end
  ensure
    fresh&.disconnect!
  end

  test "a tenant cannot write a row belonging to another" do
    assert_raises(ActiveRecord::StatementInvalid) do
      within(@other) { Feed.create!(type: Feed::FILE, key: "Smuggled", title: "Smuggled", tenant_id: @tenant.id) }
    end
  end

  test "a re-entrant switch costs nothing and opens nothing" do
    within(@tenant) do
      depth = ActiveRecord::Base.connection.open_transactions

      within(@tenant) do
        assert_equal depth, ActiveRecord::Base.connection.open_transactions
      end
    end
  end

  test "switching restores the outer tenant, and does so when the block raises" do
    within(@tenant) do
      within(@other) { assert_equal @other, Current.tenant }

      assert_equal @tenant, Current.tenant

      assert_raises(RuntimeError) { within(@other) { raise "boom" } }

      assert_equal @tenant, Current.tenant
    end
  end

  test "leaving a tenant leaves nothing behind on the connection" do
    within(@tenant) { Feed.create!(type: Feed::FILE, key: "Demo invoice", title: "Demo invoice") }

    assert_equal 0, Feed.unscoped.count,
                 "the setting outlived the switch, so the next request to pick up this " \
                 "connection would read the last one's rows"
  end

  test "a job carries the tenant it was enqueued in" do
    within(@tenant) { ProbeJob.perform_later }

    perform_enqueued_jobs

    assert_equal @tenant.subdomain, ProbeJob.performed_in
  end

  test "a job enqueued in one tenant does not perform in whichever ran last" do
    within(@other) { ProbeJob.perform_later }

    within(@tenant) { perform_enqueued_jobs }

    assert_equal @other.subdomain, ProbeJob.performed_in
  end

  test "a job enqueued outside a tenant is refused rather than left to guess" do
    assert_raises(Tenancy::Job::Homeless) { ProbeJob.perform_later }
  end

  test "a job that declares itself across tenants may be enqueued outside one" do
    assert_nothing_raised { SweepJob.perform_later }

    perform_enqueued_jobs

    assert_nil SweepJob.performed_in
  end

  test "the recurring sweeps are enqueued outside a tenant, as their schedule reaches them" do
    [ ScheduleFeedsJob, ScheduleSyncsJob, SweepAuditEventsJob, SweepRunsJob,
      RebuildSearchIndexJob ].each do |job|
      assert job.across_tenants, "#{job} is reached by the scheduler, which holds no tenant"
    end
  end

  test "the recurring commands are enqueued outside a tenant, as their schedule reaches them" do
    commands = Rails.application.config_for(:recurring, env: "production").select { |_, task| task[:command] }

    assert_includes commands.keys, :clear_solid_queue_finished_jobs

    commands.each do |key, task|
      assert_enqueued_with(job: SolidQueue::RecurringJob, args: [ task[:command] ]) do
        assert SolidQueue::RecurringTask.from_configuration(key, **task).enqueue(at: Time.current), key
      end
    end
  end
end
