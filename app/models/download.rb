require "net/http"
require "uri"

class Download
  class Failed < StandardError; end
  class Blocked < Failed; end
  class TooBig < Failed; end

  Got = Data.define(:url, :final_url, :filename, :content_type, :bytes)

  MAX_BYTES = 100.megabytes
  MAX_REDIRECTS = 4
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30
  AGENT = "xixo"

  EXTENSIONS = {
    "application/pdf" => ".pdf",
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/heic" => ".heic",
    "image/tiff" => ".tif",
    "text/plain" => ".txt",
    "text/markdown" => ".md",
    "text/csv" => ".csv",
    "text/calendar" => ".ics",
    "text/vcard" => ".vcf",
    "application/json" => ".json",
    "application/xml" => ".xml",
    "text/xml" => ".xml",
    "message/rfc822" => ".eml",
    "application/msword" => ".doc",
    "application/vnd.ms-excel" => ".xls",
    "application/vnd.apple.pkpass" => ".pkpass",
    "application/vnd.oasis.opendocument.text" => ".odt",
    "application/vnd.oasis.opendocument.spreadsheet" => ".ods",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ".xlsx"
  }.freeze

  def self.of(url, max_bytes: MAX_BYTES)
    new(url, max_bytes: max_bytes).get
  end

  def initialize(url, max_bytes: MAX_BYTES)
    @url = url.to_s
    @max_bytes = max_bytes
  end

  def get
    reach(pinned!(url), MAX_REDIRECTS)
  end

  private

    attr_reader :url, :max_bytes

    # Every hop is checked, not just the one we were handed. A public address
    # that answers with a redirect to 169.254.169.254 is the whole attack, and
    # only re-resolving each Location closes it.
    def pinned!(target)
      PublicAddress.pinned!(target)
    rescue PublicAddress::Blocked => e
      raise Blocked, e.message
    rescue PublicAddress::Unresolvable => e
      raise Failed, e.message
    end

    def reach(pinned, redirects)
      uri = pinned.uri

      PublicAddress.start(pinned, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(get_for(uri)) do |response|
          case response
          when Net::HTTPRedirection then return follow(uri, response, redirects)
          when Net::HTTPSuccess then return took(uri, response)
          else raise Failed, "#{uri} answered #{response.code}"
          end
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError,
           OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
      raise Failed, "#{e.class.name.demodulize} fetching #{uri}"
    end

    def get_for(uri)
      Net::HTTP::Get.new(uri).tap do |request|
        request["User-Agent"] = AGENT
        request["Accept"] = "*/*"
      end
    end

    def follow(uri, response, redirects)
      raise Failed, "#{url} redirected more than #{MAX_REDIRECTS} times" if redirects.zero?

      location = response["location"].to_s
      raise Failed, "#{uri} redirected without saying where" if location.blank?

      reach(pinned!(URI.join(uri, location).to_s), redirects - 1)
    rescue URI::Error
      raise Failed, "#{uri} redirected somewhere unreadable"
    end

    def took(uri, response)
      declared!(response)
      content_type = response["content-type"].to_s.split(";").first.to_s.strip.downcase

      Got.new(
        url: url,
        final_url: uri.to_s,
        filename: filename_for(uri, response["content-disposition"], content_type),
        content_type: content_type.presence,
        bytes: drain(response)
      )
    end

    def declared!(response)
      length = response["content-length"].to_s
      return if length.blank?

      raise TooBig, "#{url} is #{length} bytes, over the #{max_bytes} ceiling" if length.to_i > max_bytes
    end

    def drain(response)
      held = +"".b

      response.read_body do |chunk|
        held << chunk

        raise TooBig, "#{url} is more than #{max_bytes} bytes" if held.bytesize > max_bytes
      end

      held
    end

    def filename_for(uri, disposition, content_type)
      given = attached(disposition).presence || from_path(uri).presence
      name = Intake.named(given || "download", fallback: "download")

      File.extname(name).present? ? name : "#{name}#{EXTENSIONS.fetch(content_type, '')}"
    end

    def attached(disposition)
      return nil if disposition.blank?

      encoded = disposition[/filename\*\s*=\s*[^']*'[^']*'([^;]+)/i]
      return CGI.unescape($1.strip) if encoded

      disposition[/filename\s*=\s*"([^"]+)"/i, 1] || disposition[/filename\s*=\s*([^;]+)/i, 1]&.strip
    end

    def from_path(uri)
      URI.decode_www_form_component(uri.path.to_s.split("/").last.to_s).presence
    rescue ArgumentError
      nil
    end
end
