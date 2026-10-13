class LinkExchange < ApplicationRecord
  include TenantScoped

  STATUSES = %w[asked answered refused].freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  KEPT_FOR = 2.hours
  MOST_RECEIVED = 4.gigabytes
  MOST_FILES = 256
  MOST_HELD = 8.gigabytes
  MOST_OPEN = 64
  MOST_SEQ = 2**31 - 1
  CHUNKED = %w[read file].freeze
  UPLOAD = "upload".freeze
  FETCHED_WITHIN = 15.minutes
  MOST_PART = 4.megabytes
  PART_CHUNKS = 16

  class OutOfRange < StandardError; end

  belongs_to :resource
  belongs_to :parent, class_name: "LinkExchange", optional: true
  has_many :chunks, class_name: "LinkChunk", dependent: :delete_all
  has_many :files, class_name: "LinkExchange", foreign_key: :parent_id, inverse_of: :parent, dependent: :delete_all

  validates :verb, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :asked, -> { where(status: "asked") }
  scope :open, -> { where(status: %w[asked answered]) }
  scope :stale, -> { where(updated_at: ...KEPT_FOR.ago) }

  class << self
    def for(machine, request)
      asked.find_by(resource_id: machine.id, request: request.to_s) if uuid?(request)
    end

    def receiving(machine, request, of: nil)
      return nil unless uuid?(request)

      held = open.find_by(resource_id: machine.id, request: request.to_s) || (of && file_of(machine, request, of))
      held if held && CHUNKED.include?(held.verb)
    end

    def taken!(machine, request)
      return nil unless uuid?(request)

      fresh = asked.where(resource_id: machine.id, request: request.to_s, verb: UPLOAD, parent_id: nil, expected: nil)
                   .where(created_at: FETCHED_WITHIN.ago..)
      return nil unless fresh.update_all(status: "answered", answered_at: Time.current, updated_at: Time.current) == 1

      find_by(resource_id: machine.id, request: request.to_s)
    end

    def relayed(machine, request)
      return nil unless uuid?(request)

      open.where.not(expected: nil).find_by(resource_id: machine.id, request: request.to_s, verb: UPLOAD, parent_id: nil)
    end

    def busy(ids)
      return {} if ids.empty?

      where(resource_id: ids, parent_id: nil).open.group(:resource_id).count
    end

    def crowded?(machine)
      where(resource_id: machine.id, parent_id: nil).open.count >= MOST_OPEN
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(UUID)
    end

    def apart(&block)
      return yield unless connection_pool.active_connection&.transaction_open?

      tenant = Current.tenant
      held = Thread.new do
        Thread.current.report_on_exception = false

        connection_pool.with_connection do
          tenant ? Tenant.switch(tenant) { block.call } : block.call
        end
      end

      held.value
    end

    private

      def file_of(machine, request, of)
        return nil unless uuid?(of)

        parent = open.find_by(resource_id: machine.id, request: of.to_s, parent_id: nil)
        return nil if parent.nil? || parent.verb == UPLOAD

        filed(parent, machine, request)
      end

      def filed(parent, machine, request)
        held = parent.files.find_by(resource_id: machine.id, request: request.to_s)
        return held if held
        return nil if parent.files.count >= MOST_FILES

        transaction(requires_new: true) { parent.files.create!(resource_id: machine.id, request: request, verb: "file") }
      rescue ActiveRecord::RecordNotUnique
        parent.files.find_by(resource_id: machine.id, request: request.to_s)
      end
  end

  def answer!(result)
    settle!(LinkExchange.asked, status: "answered", result: result)
  end

  def refuse!(error)
    settle!(LinkExchange.open, status: "refused", error: error.to_s.truncate(500))
  end

  def receive!(seq, bytes)
    return false if bytes.bytesize > Resource::Machine::MOST_CHUNKED || seq.to_i > MOST_SEQ
    return false if held_by_machine + bytes.bytesize > MOST_HELD

    transaction(requires_new: true) do
      grown = LinkExchange.where(id: id).where("received + ? <= ?", bytes.bytesize, MOST_RECEIVED)
                           .update_all([ "received = received + ?", bytes.bytesize ])
      raise ActiveRecord::Rollback if grown.zero?

      chunks.create!(seq: seq.to_i, bytes: bytes)
    end.present?
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def part!(from)
    LinkExchange.uncached do
      transaction do
        held = LinkExchange.lock.find(id)
        raise OutOfRange, "the upload holds #{held.expected} bytes" unless from.between?(held.sent, held.expected)

        held.parted(from - held.sent)
      end
    end
  end

  def waiting
    LinkChunk.where(link_exchange_id: id).count
  end

  def held_by_machine
    LinkExchange.open.where(resource_id: resource_id).sum(:received)
  end

  def answered?
    status == "answered"
  end

  def refused?
    status == "refused"
  end

  protected

    def parted(skip)
      held = LinkChunk.where(link_exchange_id: id, seq: sent_seq...(sent_seq + (PART_CHUNKS * 4)))
                      .order(:seq).pluck(:id, :seq, Arel.sql("octet_length(bytes)"))
      held = held.each_with_index.take_while { |(_, seq, _), index| seq == sent_seq + index }.map(&:first)

      acked = []
      while (row = held[acked.size]) && skip >= row.last
        skip -= row.last
        acked << row
      end
      raise OutOfRange, "xixo has not sent those bytes yet" if skip.positive? && held.size == acked.size

      LinkChunk.where(id: acked.map(&:first)).delete_all if acked.any?
      update_columns(sent: sent + acked.sum(&:last), sent_seq: sent_seq + acked.size, updated_at: Time.current)

      wanted = held.drop(acked.size).first(PART_CHUNKS + 1).map(&:first)
      bytes = LinkChunk.where(id: wanted).order(:seq).pluck(:bytes)
      bytes.join.byteslice(skip, MOST_PART).to_s
    end

  private

    def settle!(open, **columns)
      open.where(id: id).update_all(**columns, answered_at: Time.current, updated_at: Time.current).positive?
    end
end
