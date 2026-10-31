module MimeType
  RAW = %w[
    3fr ari arw cap cr2 cr3 crw dcr dng erf fff iiq k25 kdc mdc mos mrw
    nef nrw orf ori pef pxn raf rw2 rwl sr2 srf srw x3f
  ].freeze

  PAGE = "xixo/page".freeze
  ENTRY = "xixo/entry".freeze
  NOTE = "text/markdown".freeze
  DEFAULT = "application/octet-stream".freeze

  TEXT = %w[
    txt rb rake gemspec py js mjs cjs jsx ts tsx go rs java kt swift php
    c h cc cpp hpp cs sh bash zsh fish sql yml yaml toml ini cfg conf env
    erb graphql proto lock
  ].freeze

  BY_EXTENSION = {
    "pdf" => "application/pdf",
    "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
    "gif" => "image/gif", "webp" => "image/webp", "heic" => "image/heic",
    "tif" => "image/tiff", "tiff" => "image/tiff", "bmp" => "image/bmp",
    "ico" => "image/vnd.microsoft.icon", "svg" => "image/svg+xml",
    "md" => "text/markdown", "markdown" => "text/markdown", "mdx" => "text/markdown",
    "rtf" => "text/rtf", "html" => "text/html", "css" => "text/css",
    "scss" => "text/css", "sass" => "text/css", "less" => "text/css",
    "csv" => "text/csv", "tsv" => "text/tab-separated-values",
    "json" => "application/json", "xml" => "application/xml",
    "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "xls" => "application/vnd.ms-excel",
    "ods" => "application/vnd.oasis.opendocument.spreadsheet",
    "doc" => "application/msword",
    "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "odt" => "application/vnd.oasis.opendocument.text",
    "mp3" => "audio/mpeg", "m4a" => "audio/mp4", "m4b" => "audio/mp4",
    "wav" => "audio/wav", "flac" => "audio/flac", "ogg" => "audio/ogg",
    "oga" => "audio/ogg", "opus" => "audio/opus", "aac" => "audio/aac",
    "wma" => "audio/x-ms-wma", "aiff" => "audio/aiff", "aif" => "audio/aiff",
    "mp4" => "video/mp4", "m4v" => "video/mp4", "mov" => "video/quicktime",
    "mkv" => "video/x-matroska", "webm" => "video/webm", "avi" => "video/x-msvideo",
    "wmv" => "video/x-ms-wmv", "mpg" => "video/mpeg", "mpeg" => "video/mpeg",
    "ics" => "text/calendar",
    "vcf" => "text/vcard", "vcard" => "text/vcard",
    "pkpass" => "application/vnd.apple.pkpass",
    "eml" => "message/rfc822",
    "zip" => "application/zip",
    "epub" => "application/epub+zip"
  }.merge(TEXT.index_with("text/plain"))
   .merge(RAW.index_with("image/x-dcraw"))
   .freeze

  ANIMATABLE = %w[image/gif image/webp image/apng].freeze

  SHEETS = %w[
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-excel
    application/vnd.oasis.opendocument.spreadsheet
  ].freeze

  DOCS = %w[
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.oasis.opendocument.text
  ].freeze

  DATA = %w[application/json application/xml text/csv text/tab-separated-values].freeze

  FAMILIES = {
    "pdf" => { exact: %w[application/pdf] },
    "email" => { exact: %w[message/rfc822] },
    "calendar" => { exact: %w[text/calendar] },
    "contact" => { exact: %w[text/vcard] },
    "pkpass" => { exact: %w[application/vnd.apple.pkpass] },
    "page" => { exact: [ PAGE, ENTRY ] },
    "xlsx" => { exact: SHEETS },
    "doc" => { exact: DOCS },
    "data" => { exact: DATA },
    "image" => { prefix: "image/" },
    "video" => { prefix: "video/" },
    "audio" => { prefix: "audio/" },
    "text" => { prefix: "text/", except: %w[text/calendar text/vcard text/csv text/tab-separated-values] }
  }.freeze

  OTHER = "file".freeze

  class << self
    def for_filename(name)
      BY_EXTENSION.fetch(extension(name), DEFAULT)
    end

    def raw?(name)
      RAW.include?(extension(name))
    end

    def extension(name)
      File.extname(name.to_s).delete(".").downcase
    end

    def image?(mime) = mime.to_s.start_with?("image/")
    def animatable?(mime) = ANIMATABLE.include?(mime.to_s)
    def audio?(mime) = mime.to_s.start_with?("audio/")
    def video?(mime) = mime.to_s.start_with?("video/")

    def text?(mime)
      mime.to_s.start_with?("text/") && !%w[text/calendar text/vcard].include?(mime.to_s)
    end

    def families
      FAMILIES.keys + [ OTHER ]
    end

    def of_kind(relation, column, family)
      rule = FAMILIES[family.to_s]

      if rule.nil?
        known = FAMILIES.values.flat_map { |held| held[:exact].to_a }
        prefixes = FAMILIES.values.filter_map { |held| held[:prefix] }
        relation.where(column => nil)
                .or(relation.where.not(column => known).where.not(prefixes.map { "#{column} LIKE ?" }.join(" OR "), *prefixes.map { |prefix| "#{prefix}%" }))
      elsif rule[:exact]
        relation.where(column => rule[:exact])
      else
        relation.where("#{column} LIKE ?", "#{rule[:prefix]}%").where.not(column => Array(rule[:except]))
      end
    end

    def family(mime)
      held = mime.to_s.downcase

      FAMILIES.each do |name, rule|
        return name if rule[:exact]&.include?(held)
        return name if rule[:prefix] && held.start_with?(rule[:prefix]) && !Array(rule[:except]).include?(held)
      end

      OTHER
    end
  end
end
