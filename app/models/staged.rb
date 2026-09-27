class Staged
  ANALYZED_AT = "analyzed_at".freeze
  PATH = "path".freeze
  SOURCE = "source_url".freeze
  DIGEST = "digest".freeze

  attr_reader :feed, :blob

  def self.stage!(feed, path:, body:, mime:, source: nil, digest: nil)
    io = body.respond_to?(:read) ? body : StringIO.new(body.to_s)
    metadata = { PATH => path, SOURCE => source.presence, DIGEST => digest.presence }.compact

    blob = ActiveStorage::Blob.create_and_upload!(
      io: io, filename: File.basename(path), content_type: mime,
      metadata: metadata, identify: false
    )

    feed.upload.attach(blob)
    new(feed)
  end

  def initialize(feed)
    @feed = feed
    @blob = feed.upload.blob
  end

  def id = nil
  def tenant_id = feed.tenant_id
  def updated_at = blob.created_at
  def changed_at = nil
  def locator = {}

  def path = blob.metadata[PATH].presence || blob.filename.to_s
  def locator_key = path
  def filename = File.basename(path)
  def mime = blob.content_type
  def size = blob.byte_size
  def source = blob.metadata[SOURCE]
  def digest = blob.metadata[DIGEST].presence

  def content_type
    mime.presence || "application/octet-stream"
  end

  def download
    service = blob.service

    return File.open(service.path_for(blob.key), "rb") if service.respond_to?(:path_for)

    StringIO.new(blob.download)
  end

  def analyzed!
    blob.update!(metadata: blob.metadata.merge(ANALYZED_AT => Time.current.iso8601(6)))
  end

  def analyzed_at
    held = blob.metadata[ANALYZED_AT]

    held && Time.iso8601(held)
  end
end
