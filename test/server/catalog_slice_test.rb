require "test_helper"
require_relative "../support/machines"

class CatalogSliceTest < ActionDispatch::IntegrationTest
  include Machines

  FEEDS = <<~GQL.freeze
    query($slice: SliceInput, $types: [String!]) {
      feeds(slice: $slice, types: $types, topLevel: true) { total nodes { key unsummarized } }
    }
  GQL

  SEARCH = <<~GQL.freeze
    query($query: String, $slice: SliceInput) {
      search(query: $query, slice: $slice) { total nodes { key } }
    }
  GQL

  COUNTS = <<~GQL.freeze
    query($slice: SliceInput, $query: String) {
      sliceCounts(slice: $slice, query: $query, topLevel: true) {
        where { key count }
        analysis { key count }
        kind { key count }
        when { key count }
      }
    }
  GQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "slice-#{SecureRandom.hex(4)}", name: "Slice")
    connect!(@tenant)

    @box = machine_on(@tenant, key: "box", folders: [ "/srv/media" ])

    Tenant.switch(@tenant) do
      @server = Resource::Machine.local!
      @media = Resource::Filesystem.create!(key: "media", name: "Media", via: @box, details: { "folder" => "/srv/media" })
      @bucket = Resource::S3.create!(key: "bucket", details: { "endpoint" => "http://127.0.0.1:1" },
                                     credentials: { "access_key_id" => "k", "secret_access_key" => "s" })
      @adas = Resource::Database.create!(key: "adas", name: "Ada's", owner_subject: "ada")

      @photo = kept("photo.jpg", at: @media, mime: "image/jpeg") { |analysis| analysis.finished! }
      @clip = kept("clip.mp4", at: @media, mime: "video/mp4") { |analysis| analysis.parked!(kind: "media", machine: @box) }
      @plan = kept("plan.pdf", at: @bucket, mime: "application/pdf")
      @broken = kept("broken.txt", at: @bucket, mime: "text/plain") { |analysis| analysis.finished!(error: "boom") }
      @old = kept("old.csv", at: @bucket, mime: "text/csv", added: 2.months.ago) { |analysis| analysis.finished! }
      @diary = kept("diary.txt", at: @adas, mime: "text/plain") { |analysis| analysis.finished! }

      Feed.where(id: [ @photo, @clip, @plan, @broken, @old, @diary ].map(&:id)).find_each { |feed| SearchIndex.index(feed) }
    end

    SearchIndex.refresh!
  end

  test "a slice narrows the list to one machine, or to one folder on it" do
    assert_equal %w[clip.mp4 photo.jpg], keys(FEEDS, slice: { machineId: @box.id })
    assert_equal %w[clip.mp4 photo.jpg], keys(FEEDS, slice: { resourceId: @media.id })
    assert_equal %w[broken.txt diary.txt old.csv plan.pdf], keys(FEEDS, slice: { machineId: @server.id })
  end

  test "a slice narrows the list by how far analysis got, and a waiting row says what it waits for" do
    assert_equal %w[diary.txt old.csv photo.jpg], keys(FEEDS, slice: { analysis: "analyzed" })
    assert_equal %w[plan.pdf], keys(FEEDS, slice: { analysis: "waiting" })
    assert_equal %w[clip.mp4], keys(FEEDS, slice: { analysis: "parked" })
    assert_equal %w[broken.txt], keys(FEEDS, slice: { analysis: "failed" })

    parked = execute(FEEDS, variables: { slice: { analysis: "parked" } }).dig("data", "feeds", "nodes").first
    assert_match(/Waiting for box/, parked["unsummarized"])
  end

  test "a slice narrows the list by kind and by when it was added, and the parts combine" do
    assert_equal %w[photo.jpg], keys(FEEDS, slice: { kind: "image" })
    assert_equal %w[broken.txt diary.txt], keys(FEEDS, slice: { kind: "text" })
    assert_equal %w[old.csv], keys(FEEDS, slice: { kind: "data" })
    assert_equal %w[broken.txt clip.mp4 diary.txt photo.jpg plan.pdf], keys(FEEDS, slice: { since: 1.week.ago.iso8601 })
    assert_equal %w[old.csv], keys(FEEDS, slice: { before: 1.week.ago.iso8601 })
    assert_equal %w[photo.jpg], keys(FEEDS, slice: { machineId: @box.id, analysis: "analyzed", since: 1.week.ago.iso8601 })
    assert_equal [], keys(FEEDS, slice: { machineId: @box.id, kind: "pdf" })
  end

  test "the counts say what each choice would show, with the rest of the slice applied" do
    counts = execute(COUNTS, variables: {}).dig("data", "sliceCounts")

    assert_equal({ @media.id.to_s => 2, @bucket.id.to_s => 3, @adas.id.to_s => 1 }, tallied(counts["where"]))
    assert_equal({ "analyzed" => 3, "waiting" => 1, "parked" => 1, "failed" => 1 }, tallied(counts["analysis"]))
    assert_equal({ "image" => 1, "video" => 1, "pdf" => 1, "text" => 2, "data" => 1 }, tallied(counts["kind"]).reject { |_key, count| count.zero? })
    assert_equal({ "day" => 5, "week" => 5, "month" => 5, "year" => 6 }, tallied(counts["when"]))

    narrowed = execute(COUNTS, variables: { slice: { machineId: @box.id } }).dig("data", "sliceCounts")

    assert_equal({ @media.id.to_s => 2, @bucket.id.to_s => 3, @adas.id.to_s => 1 }, tallied(narrowed["where"]))
    assert_equal({ "analyzed" => 1, "waiting" => 0, "parked" => 1, "failed" => 0 }, tallied(narrowed["analysis"]))
    assert_equal({ "image" => 1, "video" => 1 }, tallied(narrowed["kind"]).reject { |_key, count| count.zero? })
  end

  test "a search narrowed by a slice keeps only what the slice matches, and counts among its matches" do
    assert_equal %w[photo.jpg clip.mp4 plan.pdf broken.txt old.csv diary.txt].sort, keys(SEARCH, query: nil).sort
    assert_equal %w[clip.mp4 photo.jpg], keys(SEARCH, query: nil, slice: { machineId: @box.id }).sort
    assert_equal %w[clip.mp4], keys(SEARCH, query: nil, slice: { machineId: @box.id, analysis: "parked" })
    assert_equal %w[broken.txt diary.txt], keys(SEARCH, query: "txt", slice: { kind: "text" }).sort
    assert_equal 2, execute(SEARCH, variables: { query: "txt", slice: { kind: "text" } }).dig("data", "search", "total")

    counts = execute(COUNTS, variables: { query: "txt" }).dig("data", "sliceCounts")

    assert_equal({ "text" => 2 }, tallied(counts["kind"]).reject { |_key, count| count.zero? })
  end

  test "a state or a kind that is not one of the choices is refused" do
    assert_match(/analysis is one of analyzed, waiting, parked, failed/, execute(FEEDS, variables: { slice: { analysis: "lost" } }).dig("errors", 0, "message"))
    assert_match(/kind is one of/, execute(SEARCH, variables: { slice: { kind: "sheet" } }).dig("errors", 0, "message"))
  end

  test "somebody else's place is neither counted nor sliced on for anyone but them" do
    counts = execute(COUNTS, variables: {}, as: "bob").dig("data", "sliceCounts")

    assert_nil tallied(counts["where"])[@adas.id.to_s]
    assert_equal [], keys(FEEDS, as: "bob", slice: { resourceId: @adas.id })
    assert_equal %w[diary.txt], keys(FEEDS, as: "ada", slice: { resourceId: @adas.id })
  end

  private

    def kept(key, at:, mime:, added: Time.current)
      feed = Feed.create!(type: Feed::FILE, key: key, title: key, created_at: added)
      Reference.record!(feed: feed, resource: at, locator_key: key, locator: { "key" => key }, mime: mime)

      yield Analysis.open!(feed: feed, cause: "sync") if block_given?

      feed
    end

    def keys(query, as: "ada", **variables)
      field = query.include?("search(") ? "search" : "feeds"
      body = execute(query, variables: variables, as: as)

      assert_nil body["errors"], body["errors"].inspect
      body.dig("data", field, "nodes").map { |node| node["key"] }.sort
    end

    def tallied(counts)
      counts.to_h { |held| [ held["key"], held["count"] ] }
    end

    def execute(query, variables: nil, as: "ada")
      token = issuer.mint(subdomain: @tenant.subdomain, subject: as, scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
