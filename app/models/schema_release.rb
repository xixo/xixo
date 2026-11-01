class SchemaRelease
  KEY = "xixo_release:".freeze
  MOST = 40

  Held = Data.define(:version, :latest, :count, :at) do
    def commit = version.to_s.split("+")[1]
    def numbered = version.to_s.split("+").first

    def built?(revision, named)
      return revision.to_s.start_with?(commit) if commit.present? && revision.present?

      named.present? && named == numbered
    end
  end

  class << self
    def version = Resource::Machine::Downloads.version

    def record!
      held = version
      return if held.blank?

      metadata[KEY + held] = { "latest" => known.max, "count" => known.size, "at" => Time.current.utc.iso8601 }.to_json
      stale = recorded.sort_by(&:at).reverse.drop(MOST).map { |old| KEY + old.version }
      connection.delete(ActiveRecord::Base.sanitize_sql_array([ "DELETE FROM ar_internal_metadata WHERE key IN (?)", stale ])) if stale.any?
    end

    def recorded
      rows = connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ "SELECT key, value FROM ar_internal_metadata WHERE key LIKE ?", "#{KEY}%" ]))
      rows.filter_map do |key, value|
        held = JSON.parse(value)
        Held.new(version: key.delete_prefix(KEY), latest: held["latest"].to_i, count: held["count"].to_i, at: held["at"].to_s) if held.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def known = migrations.migrations.map(&:version)
    def applied = migrations.get_all_versions
    def ahead = (applied - known).sort

    def ahead_from
      newest = known.max.to_i
      recorded.select { |held| held.latest > newest }.max_by(&:latest)&.version
    end

    def previous(revision:, version:)
      recorded.find { |held| held.built?(revision, version) }
    end

    def migration_note
      behind = ahead
      return nil if behind.empty?

      "The database holds #{counted(behind.size)} from #{ahead_from || 'a newer build'} that this build does not have. " \
        "A release adds to the database and removes one release later, so this build runs on it."
    end

    def rollback_note(revision:, version:)
      before = previous(revision: revision, version: version)
      return nil unless before

      added = known.count { |held| held > before.latest }
      return "Rolling back to #{before.version} crosses no migration." if added.zero?

      "Rolling back to #{before.version} keeps the #{counted(added)} this build added. " \
        "#{before.version} runs on them, because a release only adds to the database."
    end

    private

      def counted(number) = "#{number} #{'migration'.pluralize(number)}"
      def metadata = pool.internal_metadata
      def migrations = pool.migration_context
      def pool = ActiveRecord::Base.connection_pool
      def connection = ActiveRecord::Base.connection
  end
end
