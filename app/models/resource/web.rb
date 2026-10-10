require "digest"

class Resource
  class Web < Resource
    class Gone < Resource::Failed; end

    PREFIX = "snapshots"
    MAX_TEXT = 100_000
    LIST = 200
    WATCHING = 100
    LONGEST = 2_048

    serves :browser

    before_validation :settle_watchlist
    validate :every_watched_address_is_one

    def self.attaching
      {
        label: "The web",
        blurb: "What renders an address into a page you keep. One is enough for a tenant — " \
               "snapshots go to your default storage. Pages on its watchlist are taken again each sync.",
        names: "A name for it",
        fields: [
          field("width", "Render width", kind: "integer", value: "1280",
                help: "How wide the window is when the page is taken."),
          field("watchlist", "Watchlist", kind: "list", placeholder: "https://example.com/changelog",
                help: "Addresses to take again on every sync, one per line. A page that changes " \
                      "becomes a new version of its item. Left empty, it only snapshots on request.")
        ]
      }
    end

    def self.command_schema
      {
        snapshot: { url: "string", width: "integer?", full_page: "boolean?" },
        list: { limit: "integer?" },
        get: { url: "string" },
        watch: { url: "string" },
        unwatch: { url: "string" }
      }
    end

    def watchlist
      Array(details.to_h["watchlist"]).map { |url| url.to_s.strip }.compact_blank.map { |url| canonical(url) }.uniq
    end

    def syncable?
      watchlist.any?
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      pending = watchlist
      pending = pending.drop(pending.index(cursor) + 1) if cursor.present? && pending.include?(cursor)

      pending.each { |url| yield [ url ], url }
    end

    def keep!(url, cause: "sync")
      reference = snapshot!(url)
      reference.update_columns(seen_at: Time.current, gone_at: nil) if cause == "sync"
      reference
    rescue Snapshot::Unavailable => e
      raise Resource::Unusable, "#{key}: #{e.message}"
    rescue Snapshot::Failed, PublicAddress::Blocked, PublicAddress::Unresolvable => e
      references.find_by(locator_key: canonical(url))&.update_columns(seen_at: Time.current) if cause == "sync"
      raise Resource::Skipped, "#{url}: #{e.message}"
    end

    def check!
      unless Snapshot.available?
        raise Resource::Unusable,
              "#{key}: no browser to render with — install chromium or set XIXO_CHROME_PATH"
      end

      storage
      true
    end

    def mime_for(_object)
      MimeType::PAGE
    end

    def version_for(locator)
      locator.to_h["digest"].presence
    end

    def locator_key_for(object)
      canonical(object)
    end

    def title_for(object)
      object.to_s
    end

    # The bytes are a rendering, not something the origin will hand back a second
    # time — visiting again produces a different page. So a snapshot is written
    # into a storage resource and the locator remembers which one, rather than
    # being re-fetched from the URL it came from.
    def storage
      named = details["storage"].presence
      found = named ? Resource.stores.shared.order(:id).find_by(key: named) : Resource.default_storage

      if found.nil?
        raise Resource::Unusable,
              "#{key}: #{named || 'this tenant'} has no storage to put a snapshot in"
      end

      found.storage!
    end

    def snapshot!(url, width: nil, full_page: nil)
      capture = Snapshot.of(canonical(url), width: width || details["width"],
                                            full_page: full_page.nil? ? true : full_page)

      record!(capture)
    end

    def download(locator)
      where = holding(locator)
      where.download(locator.fetch("png"))
    rescue KeyError
      raise Gone, "#{key}: #{locator['url']} has no snapshot stored against it"
    end

    def read(locator)
      where = holding(locator)
      where.download(locator.fetch("text")).read.force_encoding(Encoding::UTF_8).scrub
    rescue KeyError, Resource::Failed
      ""
    end

    def command_snapshot(url:, width: nil, full_page: nil)
      described(snapshot!(url, width: width, full_page: full_page))
    end

    def command_list(limit: nil)
      count = (limit || 50).to_i.clamp(1, LIST)

      {
        "watching" => watchlist,
        "snapshots" => references.order(created_at: :desc).limit(count)
                                 .map { |reference| summary(reference.locator) }
      }
    end

    def command_watch(url:)
      watching = canonical(url.to_s.strip)
      self.details = details.to_h.merge("watchlist" => (watchlist + [ watching ]).uniq)
      raise Resource::Refused, errors.full_messages.to_sentence unless save

      { "watching" => watchlist }
    end

    def command_unwatch(url:)
      dropped = canonical(url.to_s.strip)
      raise Gone, "#{key}: #{url} is not on the watchlist" unless watchlist.include?(dropped)

      self.details = details.to_h.merge("watchlist" => watchlist - [ dropped ])
      self.sync_interval = nil if watchlist.empty?
      raise Resource::Refused, errors.full_messages.to_sentence unless save

      { "watching" => watchlist }
    end

    def command_get(url:)
      reference = references.find_by(locator_key: canonical(url))
      raise Gone, "#{key}: nothing snapshotted at #{url}" if reference.nil?

      summary(reference.locator).merge("text" => read(reference.locator).truncate(MAX_TEXT))
    end

    private

      def references
        Reference.where(resource_id: id)
      end

      def settle_watchlist
        return unless details.to_h.key?("watchlist")

        settled = watchlist
        self.details = settled.empty? ? details.to_h.except("watchlist") : details.to_h.merge("watchlist" => settled)
      end

      def every_watched_address_is_one
        if watchlist.size > WATCHING
          errors.add(:base, "a watchlist holds at most #{WATCHING} addresses")
        end

        watchlist.each do |url|
          refusal = refusal_for(url)
          errors.add(:base, "#{url.truncate(200)} #{refusal}") if refusal
        end
      end

      def refusal_for(url)
        return "is longer than #{LONGEST} characters" if url.length > LONGEST

        uri = URI.parse(url)
        return "is not an http or https address" unless uri.is_a?(URI::HTTP) && uri.hostname.present?
        return "carries a username or password" if uri.userinfo.present?

        literal = literal_address(uri.hostname)
        "is not a public address" if literal && !PublicAddress.allowed? && PublicAddress.reserved?(literal)
      rescue URI::InvalidURIError
        "is not an address"
      end

      def literal_address(host)
        IPAddr.new(host)
      rescue IPAddr::Error
        nil
      end

      def record!(capture)
        stored = write!(capture)

        reference = Reference.discover!(
          resource: self,
          locator: stored,
          locator_key: canonical(capture.url),
          mime: MimeType::PAGE,
          title: capture.title.presence || capture.url
        )

        retitle!(reference, capture)
        analyse!(reference)
        reference
      end

      def write!(capture)
        where = storage
        digest = Digest::SHA256.hexdigest(capture.png)
        stem = "#{PREFIX}/#{capture.taken_at.utc.strftime('%Y%m%dT%H%M%S')}-#{digest.first(16)}"

        {
          "url" => canonical(capture.url),
          "final_url" => capture.final_url,
          "title" => capture.title,
          "taken_at" => capture.taken_at.utc.iso8601,
          "width" => capture.width,
          "height" => capture.height,
          "digest" => digest,
          "storage" => where.key,
          "storage_type" => where.type,
          "png" => where.upload("#{stem}.png", capture.png),
          "text" => where.upload("#{stem}.txt", capture.text.to_s)
        }
      end

      def retitle!(reference, capture)
        title = capture.title.presence
        return if title.blank? || reference.feed.title == title

        reference.feed.update!(title: title)
      end

      def analyse!(reference)
        return if reference.analyzed_at.present?

        reference.feed.analyze!(cause: "sync")
      end

      def holding(locator)
        held = locator.to_h
        named = held["storage"].presence
        found = (named ? stored_in(named, held["storage_type"].presence) : nil) || storage

        found.storage!
      end

      def stored_in(named, type)
        candidates = Resource.shared.serving_as(:storage).where.not(key: INTERNAL.keys.map(&:to_s)).where(key: named)
        candidates = candidates.where(type: type) if type
        candidates.order(:id).first
      end

      def described(reference)
        summary(reference.locator).merge(
          "id" => reference.feed_id.to_s,
          "mime" => reference.mime,
          "new" => reference.previously_new_record?
        )
      end

      def summary(locator)
        locator.to_h.slice("url", "final_url", "title", "taken_at", "width", "height", "digest")
      end

      def canonical(url)
        uri = URI.parse(url.to_s)
        uri.fragment = nil
        uri.path = "/" if uri.path.blank?
        uri.to_s
      rescue URI::InvalidURIError
        url.to_s
      end
  end
end
