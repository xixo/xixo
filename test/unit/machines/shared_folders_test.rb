require "test_helper"
require_relative "../../support/machines"

class SharedFoldersTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "shared-#{SecureRandom.hex(4)}", name: "Shared")
    @machine = machine_on(@tenant, key: "media", folders: [], operators: [ "alice" ])
  end

  test "every folder a machine shares joins the catalog when it says hello, held for its operators and syncing at once" do
    Tenant.switch(@tenant) do
      greet([ "/srv/media/Movies", "/srv/data/Documents" ])

      folders = Resource::Filesystem.where(via_id: @machine.id).order(:key)
      assert_equal %w[media-documents media-movies], folders.map(&:key)
      assert_equal [ "Documents on media", "Movies on media" ], folders.map(&:name)
      assert folders.all?(&:for_operators?)
      assert folders.all? { |folder| folder.owner_subject.nil? }
      assert_equal [ Resource::Machine::SharedFolders::SYNCED_EVERY.to_i ] * 2, folders.map(&:sync_interval)
      assert_equal 2, Run.where(kind: "sync", resource_id: folders.ids).count

      greet([ "/srv/media/Movies", "/srv/data/Documents" ])
      assert_equal 2, Resource::Filesystem.where(via_id: @machine.id).count
    end
  end

  test "a folder attached by hand is taken in, never doubled, and keeps who sees it" do
    Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("machine" => @machine.machine.merge("folders" => [ "/srv/media/Movies" ])))
      movies = Resource::Filesystem.create!(key: "movies", details: { "folder" => "/srv/media/Movies" }, via: @machine)

      greet([ "/srv/media/Movies" ])

      assert_equal [ movies.id ], Resource::Filesystem.where(via_id: @machine.id).ids
      movies.reload
      assert_not movies.for_operators?
      assert_equal true, movies.details["shared"]
      assert_equal Resource::Machine::SharedFolders::SYNCED_EVERY.to_i, movies.sync_interval

      movies.update!(sync_interval: nil)
      greet([ "/srv/media/Movies" ])
      assert_nil movies.reload.sync_interval
    end
  end

  test "a key another folder holds gets a number" do
    Tenant.switch(@tenant) do
      other = machine_on(@tenant, key: "other", folders: [ "/srv/media" ])
      Resource::Filesystem.create!(key: "media-movies", details: { "folder" => "/srv/media" }, via: other)

      greet([ "/srv/media/Movies" ])

      assert_equal [ "media-movies-2" ], Resource::Filesystem.where(via_id: @machine.id).pluck(:key)
    end
  end

  test "a folder the machine stops sharing is put away with its items, and comes back when it is shared again" do
    Tenant.switch(@tenant) do
      greet([ "/srv/media/Movies", "/srv/media/Books" ])
      books = Resource::Filesystem.find_by!(key: "media-books")
      reference = Reference.discover!(resource: books, locator: { "path" => "a.epub" }, locator_key: "a.epub",
                                      mime: "application/epub+zip", title: "a.epub")

      greet([ "/srv/media/Movies" ])

      assert books.reload.archived_at.present?
      assert Reference.exists?(reference.id)
      assert Resource::Filesystem.find_by!(key: "media-movies").archived_at.nil?

      greet([ "/srv/media/Movies", "/srv/media/Books" ])

      assert_nil books.reload.archived_at
      assert_not books.details.key?("unshared_at")
      assert_equal 1, Resource::Filesystem.where(via_id: @machine.id, key: "media-books").count
    end
  end

  test "a folder someone put away stays put away" do
    Tenant.switch(@tenant) do
      greet([ "/srv/media/Music" ])
      music = Resource::Filesystem.find_by!(key: "media-music")
      assert music.put_away

      greet([ "/srv/media/Music" ])

      assert music.reload.archived_at.present?
      assert_equal 1, Resource::Filesystem.where(via_id: @machine.id).count
    end
  end

  test "only the machine's operators see its folders and what they hold, until an administrator shows them to everyone" do
    documents, feed = Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("operators" => [ "alice", "bob" ]))
      greet([ "/srv/data/Documents" ])
      held = Resource::Filesystem.find_by!(key: "media-documents")
      [ held, filed(held) ]
    end

    Tenant.switch(@tenant) do
      assert_equal %w[alice bob], feed.reload.readers
      assert_includes Resource.visible_to(grant("alice")), documents
      assert_includes Resource.visible_to(grant("bob")), documents
      assert_not_includes Resource.visible_to(grant("carol")), documents
      assert_not_includes Resource.visible_to(grant("dana", administrator: true)), documents
      assert_not_includes Resource.visible_to(nil), documents
      assert_not_includes Resource.shared, documents
      assert_not_includes Feed.readable_by(grant("carol")), feed
      assert_not_includes Feed.readable_by(grant("dana", administrator: true)), feed
      assert_includes Feed.readable_by(grant("bob")), feed
      assert documents.managed_by?(grant("alice", administrator: true))
      assert_not documents.managed_by?(grant("bob"))
      assert_not documents.managed_by?(grant("dana", administrator: true))

      refused = assert_raises(Resource::Refused) { @machine.hold_for!(documents, everyone: true, grant: grant("bob")) }
      assert_match(/only an administrator/, refused.message)

      @machine.hold_for!(documents, everyone: true, grant: grant("alice", administrator: true))
    end
    perform_enqueued_jobs(only: SettleReadersJob)

    Tenant.switch(@tenant) do
      assert_nil feed.reload.readers
      assert_includes Resource.visible_to(grant("carol")), documents

      @machine.hold_for!(documents.reload, everyone: false, grant: grant("alice", administrator: true))
    end
    perform_enqueued_jobs(only: SettleReadersJob)

    Tenant.switch(@tenant) { assert_equal %w[alice bob], feed.reload.readers }
  end

  test "a change to who operates the machine changes who reads its folders' items" do
    documents, feed = Tenant.switch(@tenant) do
      greet([ "/srv/data/Documents" ])
      held = Resource::Filesystem.find_by!(key: "media-documents")
      [ held, filed(held) ]
    end

    Tenant.switch(@tenant) do
      assert_equal %w[alice], feed.reload.readers
      @machine.reload.update!(details: @machine.details.merge("operators" => [ "bob" ]))
    end
    perform_enqueued_jobs(only: SettleReadersJob)

    Tenant.switch(@tenant) do
      assert_equal %w[bob], feed.reload.readers
      assert_not_includes Resource.visible_to(grant("alice")), documents
      assert_includes Resource.visible_to(grant("bob")), documents

      emptied = @machine.reload
      emptied.details = emptied.details.merge("operators" => [])
      assert_not emptied.save
      assert_match(/needs at least one/, emptied.errors.full_messages.to_sentence)
    end
  end

  test "a folder held for operators is withheld from a token that does not operate the machine" do
    Tenant.switch(@tenant) do
      greet([ "/srv/data/Documents" ])

      Current.set(grant: grant("carol", administrator: true)) do
        assert @machine.send(:withheld?, "/srv/data/Documents")
      end
      Current.set(grant: grant("alice")) do
        assert_not @machine.send(:withheld?, "/srv/data/Documents")
      end
    end
  end

  test "a machine nobody operates catalogs nothing until someone does" do
    Tenant.switch(@tenant) do
      @machine.update!(details: @machine.details.merge("operators" => []))

      greet([ "/srv/media/Movies" ])
      assert_empty Resource::Filesystem.where(via_id: @machine.id)

      @machine.reload.update!(details: @machine.details.merge("operators" => [ "alice" ]))
      assert_equal [ "media-movies" ], Resource::Filesystem.where(via_id: @machine.id).pluck(:key)
    end
  end

  test "this server catalogs its folders once the first administrator adopts it" do
    Tenant.switch(@tenant) do
      local = Resource::Machine.local!
      local.greeted!({ "folders" => [ "/data/files" ] }, session: "s1")
      assert_empty Resource::Filesystem.where(via_id: local.id)

      Resource::Machine.adopted_by!(grant("alice", administrator: true))

      held = Resource::Filesystem.find_by!(via_id: local.id)
      assert_equal "files", held.key
      assert held.for_operators?
      assert_includes Resource.visible_to(grant("alice")), held
    end
  end

  test "a folder this server shares is keyed by its own name" do
    Tenant.switch(@tenant) do
      local = Resource::Machine.local!
      local.update!(details: local.details.merge("operators" => [ "alice" ], "client_id" => "local-link"))

      local.greeted!({ "folders" => [ "/data/files" ] }, session: "s1")

      held = Resource::Filesystem.find_by!(via_id: local.id)
      assert_equal "files", held.key
      assert_equal "files on this server", held.name
    end
  end

  test "putting a machine away puts its folders away with it, and they come back when it shares them again" do
    Tenant.switch(@tenant) do
      greet([ "/srv/media/Movies" ])
      movies = Resource::Filesystem.find_by!(key: "media-movies")

      assert @machine.reload.put_away(revoker: ->(*) { }), @machine.errors.full_messages.to_sentence
      assert movies.reload.archived_at.present?

      assert @machine.bring_back
      @machine.update!(details: @machine.details.merge("client_id" => "again"))
      greet([ "/srv/media/Movies" ])
      assert_nil movies.reload.archived_at
    end
  end

  test "discover names the folder resource each shared folder joined the catalog as" do
    Tenant.switch(@tenant) do
      greet([ "/srv/media/Movies" ])

      Current.set(grant: grant("alice")) do
        node = @machine.reload.command_discover["nodes"].sole
        assert_equal "media-movies", node["resource"]
      end
      Current.set(grant: grant("carol")) do
        assert_nil @machine.command_discover["nodes"].sole["resource"]
      end
    end
  end

  private

    def greet(folders)
      @machine.reload.greeted!({ "folders" => folders }, session: SecureRandom.hex(4))
    end

    def filed(folder)
      Reference.discover!(resource: folder, locator: { "path" => "tax.pdf" }, locator_key: "tax.pdf",
                          mime: "application/pdf", title: "tax.pdf").feed
    end

    def grant(subject, administrator: false)
      scopes = administrator ? Grant::SCOPES : Grant::SIGN_IN
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => scopes.join(" ")))
    end
end
