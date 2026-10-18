class Resource
  class Machine
    module SharedFolders
      extend ActiveSupport::Concern

      SYNCED_EVERY = 1.hour
      SHARED = "shared".freeze
      UNSHARED = "unshared_at".freeze

      included do
        validate :someone_operates_its_folders, if: -> { persisted? && will_save_change_to_details? }

        after_commit :operated_by_others, on: :update, if: :operators_changed?
      end

      def catalog_shared!
        return if archived_at.present? || !heard_from?

        held = Filesystem.where(via_id: id).order(:id).to_a
        cataloged = plans?("catalog") ? offered_folders : []
        cataloged.each { |path| cataloged!(path, held) }
        held.each { |folder| cataloged.include?(folder.folder) ? missed!(folder) : unshared!(folder) }
      end

      def shared_folder_name(path)
        "#{File.basename(path)} on #{local? ? 'this server' : name.presence || key}"
      end

      def shared_folder_key(path)
        slug = File.basename(path).downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-").presence || "folder"
        base = local? ? slug : "#{key}-#{slug}"
        taken = Filesystem.where("resources.key = ? OR resources.key LIKE ?", base, "#{Resource.sanitize_sql_like(base)}-%").pluck(:key)
        taken += Resource::INTERNAL.keys.map(&:to_s)

        ([ base ] + (2..).lazy.map { |n| "#{base}-#{n}" }.first(taken.size + 1)).find { |held| !taken.include?(held) }
      end

      def hold_for!(folder, everyone:, grant:)
        raise Resource::Refused, "#{folder.key} is not a folder on #{key}" unless folder.is_a?(Filesystem) && folder.via_id == id
        raise Resource::Refused, "only an administrator chooses who sees a folder. #{Grant::ADMINISTERING}" unless grant&.administers?
        raise Resource::Refused, "#{folder.key} belongs to one person, so only they see it" if folder.personal?
        raise Resource::Refused, "#{key} has no operator to keep #{folder.key} for. List one first" if !everyone && operators.empty?
        return folder if folder.for_operators? != everyone

        folder.for_operators = !everyone
        raise Resource::Refused, folder.errors.full_messages.to_sentence unless folder.save

        SettleReadersJob.perform_later([ folder.id ])
        folder
      end

      def put_away_shared!
        shared_through_it.find_each { |folder| unshared!(folder) }
        true
      end

      private

        def shared_through_it
          Filesystem.active.where(via_id: id).where("resources.details ->> ? = 'true'", SHARED)
        end

        def in_use_through_it
          super.where.not(id: shared_through_it.select(:id))
        end

        def cataloged!(path, held)
          same = held.select { |folder| folder.folder == path }
          return same.each { |folder| reshared!(folder) } if same.any?
          return if held.any? { |folder| overlapping?(folder.folder, path) }
          return if operators.empty?

          made = Filesystem.new(key: shared_folder_key(path), name: shared_folder_name(path), via: self,
                                for_operators: true, sync_interval: SYNCED_EVERY,
                                details: { "folder" => path, SHARED => true })
          return Rails.logger.warn("#{key} could not catalog #{path}: #{made.errors.full_messages.to_sentence}") unless made.save

          held << made
          made.sync!
        end

        def missed!(folder)
          return if folder.archived_at.present? || !folder.syncable?

          last = Run.where(kind: "sync", resource_id: folder.id).newest_first.first
          folder.sync! if last&.status == "failed" && last.error.to_s.start_with?("#{Resource::Offline.name}:")
        end

        def reshared!(folder)
          return adopted!(folder) unless folder.details.to_h[SHARED] == true
          return unless folder.archived_at.present? && folder.details.to_h.key?(UNSHARED)

          folder.update_columns(archived_at: nil, details: folder.details.except(UNSHARED), updated_at: Time.current)
          folder.sync! if folder.syncable?
        end

        def adopted!(folder)
          folder.details = folder.details.to_h.merge(SHARED => true)
          folder.sync_interval ||= SYNCED_EVERY
          return if folder.save

          Rails.logger.warn("#{key} could not take #{folder.key} in: #{folder.errors.full_messages.to_sentence}")
        end

        def unshared!(folder)
          return if folder.archived_at.present?

          folder.update_columns(archived_at: Time.current, updated_at: Time.current,
                                details: folder.details.to_h.merge(SHARED => true, UNSHARED => now_stamp))
        end

        def someone_operates_its_folders
          return if operators.any? || !Filesystem.exists?(via_id: id, for_operators: true)

          errors.add(:base, "#{key} holds folders for its operators, so it needs at least one. List someone, or have " \
                            "an administrator show its folders to everyone first")
        end

        def operators_changed?
          saved_change_to_details? && Array(details_before_last_save.to_h["operators"]) != operators
        end

        def operated_by_others
          held = Filesystem.where(via_id: id, for_operators: true).ids
          SettleReadersJob.perform_later(held) if held.any?
          catalog_shared!
        end
    end
  end
end
