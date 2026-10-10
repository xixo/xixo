# frozen_string_literal: true

module Types
  class MutationType < Types::BaseObject
    field :add_note, mutation: Mutations::AddNote, grants: "xixo:catalog:write"
    field :ask_catalog, mutation: Mutations::AskCatalog, grants: "xixo:catalog:write"
    field :snapshot_url, mutation: Mutations::SnapshotUrl, grants: "xixo:catalog:write"
    field :fetch_url, mutation: Mutations::FetchUrl, grants: "xixo:catalog:write"

    field :analyze_feed, mutation: Mutations::AnalyzeFeed, grants: "xixo:catalog:write"
    field :rename_feed, mutation: Mutations::RenameFeed, grants: "xixo:catalog:write"
    field :note_feed, mutation: Mutations::NoteFeed, grants: "xixo:catalog:write"
    field :set_feed_timeout, mutation: Mutations::SetFeedTimeout, grants: "xixo:catalog:write"
    field :set_feed_lifetime, mutation: Mutations::SetFeedLifetime, grants: "xixo:catalog:write"
    field :forget_feed, mutation: Mutations::ForgetFeed, grants: "xixo:catalog:write"
    field :connect_feeds, mutation: Mutations::ConnectFeeds, grants: "xixo:catalog:write"
    field :split_reference, mutation: Mutations::SplitReference, grants: "xixo:catalog:write"

    field :attach_resource, mutation: Mutations::AttachResource, grants: "xixo:resources:command"
    field :update_resource, mutation: Mutations::UpdateResource, grants: "xixo:resources:command"
    field :archive_resource, mutation: Mutations::ArchiveResource, grants: "xixo:resources:command"
    field :delete_resource, mutation: Mutations::DeleteResource, grants: "xixo:resources:command"
    field :sync_resource, mutation: Mutations::SyncResource, grants: "xixo:resources:command"
    field :check_resource, mutation: Mutations::CheckResource, grants: "xixo:resources:command"
    field :set_default_storage, mutation: Mutations::SetDefaultStorage, grants: "xixo:resources:command"
    field :set_default_inference, mutation: Mutations::SetDefaultInference, grants: "xixo:resources:command"
    field :set_sync_interval, mutation: Mutations::SetSyncInterval, grants: "xixo:resources:command"

    field :set_setting, mutation: Mutations::SetSetting, grants: "xixo:settings:write"

    field :export_feeds, mutation: Mutations::ExportFeeds, grants: "xixo:catalog:write"
    field :cancel_run, mutation: Mutations::CancelRun, grants: "xixo:catalog:write"
    field :cancel_analysis, mutation: Mutations::CancelAnalysis, grants: "xixo:catalog:write"
    field :tag_feeds, mutation: Mutations::TagFeeds, grants: "xixo:catalog:write"
    field :save_feed, mutation: Mutations::SaveFeed, grants: "xixo:catalog:write"
    field :run_feed, mutation: Mutations::RunFeed, grants: "xixo:catalog:write"
    field :pause_feed, mutation: Mutations::PauseFeed, grants: "xixo:catalog:write"
    field :delete_feed, mutation: Mutations::DeleteFeed, grants: "xixo:catalog:write"
  end
end
