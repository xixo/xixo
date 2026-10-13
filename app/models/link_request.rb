class LinkRequest < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending approved handed linked denied].freeze
  LASTS = 10.minutes
  POLLED_EVERY = 5
  ALPHABET = "BCDFGHJKLMNPQRSTVWXZ".chars.freeze
  CODE_LENGTH = 8
  CODE = /\A[#{ALPHABET.join}]{4}-?[#{ALPHABET.join}]{4}\z/
  MOST_PENDING = 20
  MOST_PENDING_FROM = 3
  MOST_HOSTNAME = 63
  KINDS = %w[laptop desktop all-in-one server].freeze
  MOST_ADDRESSES = 8
  MOST_DISKS = 16
  MOST_CPUS = 4096
  MOST_BYTES = 2**62

  class Refused < StandardError; end

  Started = Data.define(:request, :device_code)

  encrypts :enrollment_token

  belongs_to :resource, class_name: "Resource::Machine", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :hostname, :user_code, :device_digest, :expires_at, presence: true

  scope :live, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ...Time.current) }
  scope :pending, -> { live.where(status: "pending") }
  scope :shown, -> { live.where(status: %w[pending approved handed linked]).order(:created_at) }

  class << self
    def start!(said, remote_ip:)
      expired.delete_all
      raise Refused, "xixo is waiting on too many machines to link up. Try again in a few minutes" if pending.count >= MOST_PENDING
      raise Refused, "this address is already waiting on #{MOST_PENDING_FROM} machines to link up" if pending.where(remote_ip: remote_ip).count >= MOST_PENDING_FROM

      device_code = SecureRandom.urlsafe_base64(32)
      request = create!(said(said).merge(device_digest: digest(device_code), user_code: fresh_code, remote_ip: remote_ip,
                                         expires_at: LASTS.from_now))
      request.announce!

      Started.new(request: request, device_code: device_code)
    end

    def presented(device_code)
      return nil if device_code.blank? || device_code.to_s.bytesize > 128

      find_by(device_digest: digest(device_code))
    end

    def by_code(code)
      held = normalized(code)
      held && live.find_by(user_code: held)
    end

    def normalized(code)
      held = code.to_s.upcase.delete("-").strip
      return nil unless held.match?(CODE)

      "#{held[0, 4]}-#{held[4, 4]}"
    end

    def digest(code)
      Digest::SHA256.hexdigest(code.to_s)
    end

    private

      def said(said)
        said = said.to_h
        folders = Resource::Machine::Hello.folders(said["folders"])

        {
          hostname: hostname(said["hostname"]),
          os: Resource::Machine::Hello.text(said["os"])&.first(32),
          arch: Resource::Machine::Hello.text(said["arch"])&.first(32),
          folders: folders,
          writable: Resource::Machine::Hello.folders(said["writable"]) & folders,
          details: details(said["details"], folders)
        }
      end

      def details(said, folders)
        said = said.is_a?(Hash) ? said.to_h.stringify_keys : {}
        hello = Resource::Machine::Hello

        {
          "user" => hello.text(said["user"])&.first(64),
          "system" => hello.text(said["system"])&.first(80),
          "model" => hello.text(said["model"])&.first(80),
          "kind" => (said["kind"].to_s if KINDS.include?(said["kind"].to_s)),
          "version" => hello.text(said["version"])&.first(32),
          "cpus" => count(said["cpus"], MOST_CPUS),
          "memory" => count(said["memory"], MOST_BYTES),
          "disks" => disks(said["disks"], folders),
          "addresses" => hello.listed(said["addresses"]).first(MOST_ADDRESSES * 4)
                              .filter_map { |address| hello.address(address) }.uniq.first(MOST_ADDRESSES),
          "services" => hello.services(said["services"])
        }.compact
      end

      def disks(said, folders)
        Resource::Machine::Hello.listed(said).first(MOST_DISKS).filter_map do |disk|
          next unless disk.is_a?(Hash)

          disk = disk.to_h.stringify_keys
          path = Resource::Machine::Hello.folder(disk["path"])
          next unless path && (path == "/" || folders.include?(path))

          total = count(disk["total"], MOST_BYTES)
          free = count(disk["free"], MOST_BYTES)
          { "path" => path, "total" => total, "free" => [ free, total ].min } if total && free
        end.uniq { |disk| disk["path"] }
      end

      def count(value, most)
        value if value.is_a?(Integer) && value.between?(0, most)
      end

      def hostname(given)
        named = Resource::Machine::Hello.text(given).to_s.downcase.gsub(/[^a-z0-9.-]+/, "-").first(MOST_HOSTNAME)
        named = named.delete_prefix("-").delete_suffix("-")
        raise Refused, "the machine named no hostname" if named.blank?

        named
      end

      def fresh_code
        loop do
          drawn = Array.new(CODE_LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
          code = "#{drawn[0, 4]}-#{drawn[4, 4]}"
          return code unless exists?(user_code: code)
        end
      end
  end

  def live?
    expires_at > Time.current
  end

  def pending?
    status == "pending" && live?
  end

  def approve!(grant, minter: Resource::Machine::Enrollment.method(:mint))
    grant.administer!("approves a machine")

    with_lock do
      raise Refused, "that request is no longer waiting" unless pending?

      token = minter.call(tenant, name: hostname)
      update!(status: "approved", enrollment_token: token, decided_by: grant.speaks_for, decided_at: Time.current,
              expires_at: LASTS.from_now)
    end
    announce!
  end

  def deny!(grant)
    grant.administer!("denies a machine")

    with_lock do
      raise Refused, "that request is no longer waiting" unless pending?

      update!(status: "denied", decided_by: grant.speaks_for, decided_at: Time.current)
    end
    announce!
  end

  def polled!
    with_lock do
      next :expired_token unless live?
      next :access_denied if status == "denied"
      next :slow_down if polled_at && polled_at > (POLLED_EVERY - 1).seconds.ago

      update!(polled_at: Time.current)
      next :authorization_pending if status == "pending"
      next :expired_token unless status == "approved" && enrollment_token.present?

      token = enrollment_token
      update!(status: "handed", enrollment_token: nil)
      token
    end
  end

  def link!(client_id)
    raise Refused, "that is not a client id xixo link prints" unless client_id.to_s.match?(Resource::Machine::CLIENT_ID)

    machine = with_lock do
      raise Refused, "that request is not one xixo is waiting on. Run the command again" unless status == "handed" && live?
      raise Refused, "another machine is linked as that client already" if Resource::Machine.enrolled(client_id)

      made = Resource::Machine.approved!(self, client_id)
      update!(status: "linked", resource: made)
      made
    end
    announce!
    machine
  end

  def announce!
    XixoSchema.subscriptions.trigger(:link_request_changed, {}, self, scope: tenant_id)
  rescue StandardError => e
    Rails.logger.warn "link request #{id} could not announce: #{e.message}"
  end
end
