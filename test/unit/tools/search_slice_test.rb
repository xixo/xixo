require "test_helper"
require_relative "../../support/machines"

class SearchSliceTest < ActiveSupport::TestCase
  include Machines

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "sliced-#{SecureRandom.hex(4)}", name: "Sliced")
    @box = machine_on(@tenant, key: "box", folders: [ "/srv/photos" ])

    Tenant.switch(@tenant) do
      @photos = Resource::Filesystem.create!(key: "photos", name: "Photos", via: @box, details: { "folder" => "/srv/photos" })
      @photo = create_feed(mime: "image/jpeg", locator_key: "dog.jpg", resource: @photos)
      @plan = create_feed(mime: "application/pdf", locator_key: "plan.pdf")
      Analysis.open!(feed: @photo, cause: "sync").finished!
      Analysis.open!(feed: @plan, cause: "sync").parked!(kind: "pdf")
      [ @photo, @plan ].each { |feed| SearchIndex.index(feed) }
    end

    SearchIndex.refresh!
    Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))
  end

  teardown do
    Current.reset
  end

  test "an agent asks for the same slice the catalog's chips do" do
    assert_equal [ @photo.id.to_s ], ids(searched(machine_id: @box.id.to_s))
    assert_equal [ @photo.id.to_s ], ids(searched(resource_id: @photos.id.to_s))
    assert_equal [ @plan.id.to_s ], ids(searched(analysis: "parked"))
    assert_equal [ @photo.id.to_s ], ids(searched(analysis: "analyzed", kind: "image"))
    assert_equal [], ids(searched(kind: "pdf", since: 1.day.from_now.iso8601))
    assert_equal 1, searched(kind: "pdf", before: 1.day.from_now.iso8601)["total"]
  end

  test "the slice is named in what the audit log says the agent did" do
    said = Tool::Search.saying(query: "dog", machine_id: @box.id.to_s, kind: "image")

    assert_equal "searched for dog narrowed to machine_id #{@box.id}, kind image", said
  end

  test "a choice outside the slice's vocabulary comes back as a correction" do
    reply = Tenant.switch(@tenant) { Tool::Search.call(server_context: {}, analysis: "lost") }

    assert reply.error?
    assert_match(/analysis is one of analyzed, waiting, parked, failed/, reply.content.first[:text])
  end

  private

    def searched(**arguments)
      Tenant.switch(@tenant) { JSON.parse(Tool::Search.call(server_context: {}, **arguments).content.first[:text]) }
    end

    def ids(reply)
      reply.fetch("feeds").map { |held| held["id"] }
    end
end
