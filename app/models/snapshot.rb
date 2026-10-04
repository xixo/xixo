require "ferrum"
require "base64"
require "timeout"

class Snapshot
  class Failed < StandardError; end
  class Blocked < Failed; end
  class Unavailable < Failed; end

  Capture = Data.define(:url, :final_url, :title, :png, :text, :width, :height, :taken_at)

  WIDTH = 1280
  HEIGHT = 900
  WIDTHS = (320..2560).freeze
  MAX_HEIGHT = 20_000
  MAX_BYTES = 25.megabytes
  MAX_TEXT = 200_000

  NAVIGATION = 20
  SETTLE = 3
  RENDER = 60
  WHOLE = 120

  # A page composes itself out of data: and blob: URLs as well as network ones.
  # Those never leave the renderer, so they are not the guard's business.
  INLINE = %w[data blob].freeze

  # Ferrum turns the same-origin policy and site isolation off by default, which
  # suits a test suite driving its own app and not a renderer pointed at whatever
  # a caller names. A compromised renderer that can read across origins is the
  # whole risk here, so these come back on.
  UNSAFE_FLAGS = %w[disable-web-security disable-site-isolation-trials].freeze
  UNSAFE_FEATURES = %w[site-per-process IsolateOrigins].freeze

  HARDENING = {
    "block-new-web-contents" => nil,
    "deny-permission-prompts" => nil,
    "disable-file-system" => nil,
    "disable-notifications" => nil,
    "disable-speech-api" => nil,
    "no-pings" => nil
  }.freeze

  class << self
    def of(url, width: WIDTH, full_page: true)
      new(url, width: width, full_page: full_page).take
    end

    def browser_path
      ENV["XIXO_CHROME_PATH"].presence || Ferrum::Browser::Options::Chrome.instance.detect_path
    end

    def available?
      browser_path.present?
    end

    def flags(egress: nil)
      defaults = Ferrum::Browser::Options::Chrome::DEFAULT_OPTIONS.except(*UNSAFE_FLAGS)
      features = defaults["disable-features"].to_s.split(",") - UNSAFE_FEATURES

      flags = defaults.merge(HARDENING).merge("disable-features" => features.join(","))
      flags = flags.merge("no-sandbox" => nil) if Switch.on?("XIXO_CHROME_NO_SANDBOX")
      flags = flags.merge(routed(egress)) if egress
      flags
    end

    def routed(egress)
      {
        "proxy-server" => egress.address,
        "proxy-bypass-list" => "<-loopback>",
        "force-webrtc-ip-handling-policy" => "disable_non_proxied_udp",
        "disable-quic" => nil
      }
    end
  end

  def initialize(url, width: WIDTH, full_page: true)
    @url = url.to_s
    @width = (width || WIDTH).to_i.clamp(WIDTHS.min, WIDTHS.max)
    @full_page = full_page
    @verdicts = {}
  end

  def take
    target = permitted!(@url)

    unless self.class.available?
      raise Unavailable, "no browser to render with — install chromium or set XIXO_CHROME_PATH"
    end

    Timeout.timeout(WHOLE, Failed, "#{@url} did not finish rendering in #{WHOLE}s") { drive(target) }
  end

  # Whether one request the page makes is let out. A scheme other than http, https
  # and the two that never leave the renderer is refused whatever the address
  # rules say, so `file://` stays shut even where private fetches are allowed.
  def permits?(candidate)
    scheme = URI.parse(candidate.to_s).scheme.to_s.downcase
    return true if INLINE.include?(scheme)
    return false unless PublicAddress::SCHEMES.include?(scheme)

    verdicts.fetch(candidate) { verdicts[candidate] = PublicAddress.permitted?(candidate) }
  rescue URI::InvalidURIError
    false
  end

  private

    attr_reader :url, :width, :verdicts

    def full_page? = @full_page

    def drive(target)
      Egress.open do |egress|
        browser = start!(egress)
        page = browser.page

        guard(browser)
        visit(page, target)
        gather(page)
      rescue Ferrum::Error => e
        raise Failed, "#{url}: #{e.class.name.demodulize} — #{e.message.to_s.truncate(200)}"
      ensure
        shut(browser)
      end
    end

    def start!(egress)
      Ferrum::Browser.new(
        browser_path: self.class.browser_path,
        headless: true,
        incognito: true,
        ignore_default_browser_options: true,
        browser_options: self.class.flags(egress: egress),
        window_size: [ width, HEIGHT ],
        pending_connection_errors: false,
        timeout: NAVIGATION,
        process_timeout: NAVIGATION
      )
    rescue Ferrum::Error, Errno::ENOENT => e
      raise Unavailable, "could not start a browser — #{e.message.to_s.truncate(200)}"
    end

    def shut(browser)
      browser&.quit
    rescue StandardError
      nil
    end

    # PublicFetch checks one URL once. A browser resolves again, follows its own
    # redirects and lets the page ask for anything it likes, so the guard has to
    # sit on every request rather than on the one we opened with.
    def guard(browser)
      browser.network.intercept

      browser.on(:request) do |request|
        permits?(request.url) ? request.continue : request.abort
      rescue Ferrum::Error
        nil
      end
    end

    def visit(page, target)
      page.go_to(target.to_s)
      page.network.wait_for_idle(timeout: SETTLE)
    rescue Ferrum::StatusError, Ferrum::TimeoutError
      nil
    end

    def gather(page)
      taken_at = Time.current
      height = extent(page)
      png = shoot(page, height)

      if png.bytesize > MAX_BYTES
        raise Failed, "#{url} rendered #{png.bytesize} bytes, over the #{MAX_BYTES} ceiling"
      end

      Capture.new(
        url: url, final_url: current_url(page), title: title(page), png: png,
        text: text(page), width: width, height: height, taken_at: taken_at
      )
    end

    def extent(page)
      return HEIGHT unless full_page?

      _, tall = page.document_size

      tall.to_i.clamp(1, MAX_HEIGHT)
    end

    # captureBeyondViewport is what reaches below the fold, and ferrum only sets
    # it for `full: true` — which takes the document's own height, however many
    # screens of infinite scroll that turns out to be.
    def shoot(page, height)
      answer = page.command(
        "Page.captureScreenshot",
        timeout: RENDER,
        format: "png",
        captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: width, height: height, scale: 1 }
      )

      Base64.decode64(answer.fetch("data"))
    end

    def title(page)
      evaluate(page, "document.title").to_s.strip.truncate(500).presence
    end

    def current_url(page)
      evaluate(page, "window.location.href").to_s.presence || url
    end

    def text(page)
      body = evaluate(page, "document.body ? document.body.innerText : ''").to_s

      body.force_encoding(Encoding::UTF_8).scrub.squeeze("\n").strip.truncate(MAX_TEXT)
    end

    def evaluate(page, script)
      page.evaluate(script)
    rescue Ferrum::Error
      nil
    end

    def permitted!(target)
      PublicAddress.permitted!(target)
    rescue PublicAddress::Blocked => e
      raise Blocked, e.message
    rescue PublicAddress::Unresolvable => e
      raise Failed, e.message
    end
end
