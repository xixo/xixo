require "test_helper"
require Rails.root.join("db/migrate/20261012140000_move_filesystems_behind_the_local_machine").to_s

class FilesystemMigrationTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "jons-#{SecureRandom.hex(4)}", name: "Jon")
    @verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  teardown do
    ActiveRecord::Migration.verbose = @verbose
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
  end

  test "a directory on the server becomes a folder the local machine shares, keeping its files and its default" do
    ids = Tenant.switch(@tenant) do
      box = Resource::Machine.create!(key: "box", name: "Box", details: { "machine" => { "folders" => [ "/srv/media" ] } })
      files = old("filesystem", "files", { "root" => "." }, default_storage: true)
      held = {
        files: files,
        photos: old("filesystem", "photos", { "root" => "/srv/photos/", "skip" => [ "*.tmp" ] }),
        drop: old("filesystem", "drop", { "root" => "drop/in" }),
        media: old("agent-folder", "media", { "folder" => "/srv/media" }, via: box.id)
      }

      feed = Feed.create!(type: Feed::FILE, key: "report.txt", title: "report.txt")
      held[:reference] = Reference.create!(
        feed: feed, resource_id: files, locator_key: "2026/report.txt", role: Reference::ORIGINAL,
        locator: { "path" => "2026/report.txt" }
      ).id
      held[:box] = box.id
      held
    end

    ENV["XIXO_FILESYSTEM_ROOTS"] = "/data/files"
    2.times { MoveFilesystemsBehindTheLocalMachine.new.up }

    Tenant.switch(@tenant) do
      local = Resource::Machine.local
      assert_equal 1, Resource::Machine.where(key: "local").count
      assert_equal "This server", local.name
      assert local.local?

      files = Resource.find(ids[:files])
      assert_instance_of Resource::Filesystem, files
      assert_equal local, files.via
      assert_equal({ "folder" => "/data/files/#{@tenant.subdomain}" }, files.details)
      assert files.default_storage?
      assert_equal files, Resource.default_storage

      assert_equal({ "folder" => "/srv/photos", "skip" => [ "*.tmp" ] }, Resource.find(ids[:photos]).details)
      assert_equal "/data/files/#{@tenant.subdomain}/drop/in", Resource.find(ids[:drop]).details["folder"]

      media = Resource.find(ids[:media])
      assert_instance_of Resource::Filesystem, media
      assert_equal ids[:box], media.via_id

      reference = Reference.find(ids[:reference])
      assert_equal "2026/report.txt", reference.locator_key
      assert_equal files, reference.resource
    end
  end

  test "the old root defaults to the path the self-hosting guide used" do
    id = Tenant.switch(@tenant) { old("filesystem", "files", { "root" => "." }) }

    MoveFilesystemsBehindTheLocalMachine.new.up

    Tenant.switch(@tenant) do
      assert_equal "/data/files/#{@tenant.subdomain}", Resource.find(id).details["folder"]
    end
  end

  private

    def old(type, key, details, default_storage: false, via: nil)
      Resource.connection.select_value(<<~SQL.squish)
        INSERT INTO resources (tenant_id, type, key, name, details, default_storage, via_id, serving, created_at, updated_at)
        VALUES (#{@tenant.id}, #{Resource.connection.quote(type)}, #{Resource.connection.quote(key)}, #{Resource.connection.quote(key)},
                #{Resource.connection.quote(details.to_json)}::jsonb, #{default_storage}, #{via || 'NULL'},
                '{"capabilities": ["storage"], "accepts": ["*/*"]}'::jsonb, now(), now())
        RETURNING id
      SQL
    end
end
