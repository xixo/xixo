require "net/http"
require "resolv"
require "ipaddr"

module PublicAddress
  class Blocked < StandardError; end
  class Unresolvable < StandardError; end

  SCHEMES = %w[http https].freeze

  Pinned = Data.define(:uri, :address)

  RESERVED = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::/96 ::1/128 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/32 2001:db8::/32 2002::/16
    fc00::/7 fe80::/10 fec0::/10 ff00::/8
  ].map { |block| IPAddr.new(block) }.freeze

  class << self
    def allowed?
      Switch.on?("XIXO_ALLOW_PRIVATE_FETCH")
    end

    def permitted!(target, allow_private: allowed?, through: nil)
      uri = http!(target)
      return uri if allow_private && through.nil?

      vetted(uri.hostname, through)
      uri
    end

    def pinned!(target, allow_private: allowed?, through: nil)
      uri = http!(target)

      Pinned.new(uri: uri, address: address_for!(uri.hostname, allow_private: allow_private, through: through))
    end

    def address_for!(host, allow_private: allowed?, through: nil)
      raise Blocked, "no host was named" if host.blank?

      found = allow_private && through.nil? ? addresses(host) : vetted(host, through)

      found.min_by { |address| address.ipv4? ? 0 : 1 }.to_s
    end

    def start(pinned, open_timeout:, read_timeout:, &block)
      http = Net::HTTP.new(pinned.uri.hostname, pinned.uri.port)
      http.ipaddr = pinned.address
      http.use_ssl = pinned.uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.start(&block)
    end

    def origins(listed)
      listed.to_s.split(",").filter_map { |entry| origin(entry) }.uniq
    end

    def origin(target)
      uri = URI.parse(target.to_s.strip)
      "#{uri.scheme}://#{uri.host}:#{uri.port}" if uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end

    def permitted?(target, allow_private: allowed?)
      permitted!(target, allow_private: allow_private)
      true
    rescue Blocked, Unresolvable
      false
    end

    # ::ffff:127.0.0.1 is loopback wearing an IPv6 costume, and every range test
    # below answers false until it is taken off.
    def reserved?(address)
      native = address.ipv4_mapped? ? address.native : address

      RESERVED.any? { |block| block.include?(native) }
    end

    def covered?(address, ranges)
      native = address.ipv4_mapped? ? address.native : address

      Array(ranges).any? { |block| block.include?(native) }
    end

    def admitted?(address, through)
      through.nil? ? !reserved?(address) : covered?(address, through)
    end

    def addresses(host)
      literal = numeric(host)
      return [ literal ] if literal

      found = Resolv.getaddresses(host).filter_map { |entry| numeric(entry) }
      raise Unresolvable, "#{host} does not resolve" if found.empty?

      found
    end

    private

      def http!(target)
        uri = parse(target)

        unless uri.is_a?(URI::HTTP) && uri.hostname.present?
          raise Blocked, "#{target} is not an http or https URL"
        end

        uri
      end

      def vetted(host, through = nil)
        addresses(host).each do |address|
          next if admitted?(address, through)

          refusal = through.nil? ? "is not a public address" : "is not an address its transport reaches"
          raise Blocked, "#{host} resolves to #{address}, which #{refusal}"
        end
      end

      def parse(target)
        URI.parse(target.to_s)
      rescue URI::InvalidURIError
        raise Blocked, "#{target} is not a URL"
      end

      def numeric(value)
        IPAddr.new(value.to_s)
      rescue IPAddr::Error
        nil
      end
  end
end
