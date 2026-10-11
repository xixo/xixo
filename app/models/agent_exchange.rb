class AgentExchange < ApplicationRecord
  include TenantScoped

  STATUSES = %w[asked answered refused].freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  KEPT_FOR = 1.hour
  MOST_RECEIVED = 4.gigabytes
  MOST_FILES = 256

  belongs_to :resource
  belongs_to :parent, class_name: "AgentExchange", optional: true
  has_many :chunks, class_name: "AgentChunk", dependent: :delete_all
  has_many :files, class_name: "AgentExchange", foreign_key: :parent_id, inverse_of: :parent, dependent: :delete_all

  validates :verb, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :asked, -> { where(status: "asked") }
  scope :open, -> { where(status: %w[asked answered]) }
  scope :stale, -> { where(created_at: ...KEPT_FOR.ago) }

  class << self
    def for(machine, request)
      asked.find_by(resource_id: machine.id, request: request.to_s) if uuid?(request)
    end

    def receiving(machine, request, of: nil)
      return nil unless uuid?(request)

      open.find_by(resource_id: machine.id, request: request.to_s) || (of && file_of(machine, request, of))
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(UUID)
    end

    private

      def file_of(machine, request, of)
        parent = asked.find_by(resource_id: machine.id, request: of.to_s, parent_id: nil) if uuid?(of)
        return nil if parent.nil? || parent.files.count >= MOST_FILES

        transaction(requires_new: true) { parent.files.create!(resource_id: machine.id, request: request, verb: "file") }
      rescue ActiveRecord::RecordNotUnique
        nil
      end
  end

  def answer!(result)
    settle!(AgentExchange.asked, status: "answered", result: result)
  end

  def refuse!(error)
    settle!(AgentExchange.open, status: "refused", error: error.to_s.truncate(500))
  end

  def receive!(seq, bytes)
    return false if bytes.bytesize > Resource::XixoAgent::MOST_CHUNKED

    transaction(requires_new: true) do
      grown = AgentExchange.where(id: id).where("received + ? <= ?", bytes.bytesize, MOST_RECEIVED)
                           .update_all([ "received = received + ?", bytes.bytesize ])
      raise ActiveRecord::Rollback if grown.zero?

      chunks.create!(seq: seq.to_i, bytes: bytes)
    end.present?
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def answered?
    status == "answered"
  end

  def refused?
    status == "refused"
  end

  private

    def settle!(open, **columns)
      open.where(id: id).update_all(**columns, answered_at: Time.current, updated_at: Time.current).positive?
    end
end
