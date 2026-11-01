require "test_helper"

class SchemaReleaseTest < ActiveSupport::TestCase
  AHEAD = "99990101000000".freeze

  setup do
    connection.execute("DELETE FROM ar_internal_metadata WHERE key LIKE 'xixo_release:%'")
  end

  teardown do
    connection.execute("DELETE FROM ar_internal_metadata WHERE key LIKE 'xixo_release:%'")
    connection.execute("DELETE FROM schema_migrations WHERE version = '#{AHEAD}'")
  end

  test "a boot records the migrations this build knows under its version" do
    SchemaRelease.record!

    held = uncached { SchemaRelease.recorded }.sole
    assert_equal SchemaRelease.version, held.version
    assert_equal SchemaRelease.known.max, held.latest
    assert_equal SchemaRelease.known.size, held.count
    assert_in_delta Time.current, Time.iso8601(held.at), 5
  end

  test "after a rollback the note says what the database holds from the newer build" do
    assert_nil uncached { SchemaRelease.migration_note }

    connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{AHEAD}')")
    assert_equal "The database holds 1 migration from a newer build that this build does not have. " \
                 "A release adds to the database and removes one release later, so this build runs on it.",
                 uncached { SchemaRelease.migration_note }

    record("9.9.0", latest: AHEAD.to_i)
    assert_match(/from 9\.9\.0 that/, uncached { SchemaRelease.migration_note })
  end

  test "before a rollback the note says what the build before keeps, once that build has run here" do
    assert_nil uncached { SchemaRelease.rollback_note(revision: "abcdef0123456789", version: "main") }

    record("0.1.0+abcdef0", latest: SchemaRelease.known.min)
    added = SchemaRelease.known.size - 1
    assert_equal "Rolling back to 0.1.0+abcdef0 keeps the #{added} migrations this build added. " \
                 "0.1.0+abcdef0 runs on them, because a release only adds to the database.",
                 uncached { SchemaRelease.rollback_note(revision: "abcdef0123456789", version: "main") }

    record("0.2.0", latest: SchemaRelease.known.max)
    assert_equal "Rolling back to 0.2.0 crosses no migration.",
                 uncached { SchemaRelease.rollback_note(revision: "ffff", version: "0.2.0") }
    assert_nil uncached { SchemaRelease.rollback_note(revision: "ffff", version: "0.3.0") }
  end

  test "only the newest records are kept" do
    (SchemaRelease::MOST + 5).times { |n| record("0.0.#{n}", latest: n, at: (n + 10).days.ago) }

    SchemaRelease.record!

    kept = uncached { SchemaRelease.recorded }
    assert_equal SchemaRelease::MOST, kept.size
    assert_includes kept.map(&:version), SchemaRelease.version
    assert_not_includes kept.map(&:version), "0.0.#{SchemaRelease::MOST + 4}"
  end

  private

    def connection = ActiveRecord::Base.connection

    def uncached(&) = ActiveRecord::Base.uncached(&)

    def record(version, latest:, at: Time.current)
      ActiveRecord::Base.connection_pool.internal_metadata["xixo_release:#{version}"] = { latest: latest, count: 1, at: at.utc.iso8601 }.to_json
    end
end
