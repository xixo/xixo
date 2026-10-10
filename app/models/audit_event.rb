class AuditEvent < ApplicationRecord
  include TenantScoped

  STATUSES = %w[ok error denied].freeze
  ACTORS = %w[person client agent nobody].freeze
  REDACTED = /secret|password|token|credential|authorization|access_key/i
  VALUE_LIMIT = 200
  DETAIL_LIMIT = 500

  belongs_to :analysis, optional: true
  belongs_to :feed, optional: true

  validates :channel, :action, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :actor, inclusion: { in: ACTORS }

  scope :newest_first, -> { order(id: :desc) }

  class << self
    def record(channel:, action:, status:, grant: nil, context: {}, told: nil, feed: nil, **attributes)
      create!(
        channel: channel.to_s,
        action: action.to_s,
        status: status.to_s,
        **actor(grant),
        analysis: Current.analysis,
        feed: feed,
        told: Redaction.scrub(told&.to_s&.squish)&.truncate(DETAIL_LIMIT),
        remote_ip: context[:remote_ip],
        request_id: context[:request_id],
        arguments: summarize(attributes[:arguments]),
        detail: Redaction.scrub(attributes[:detail]&.to_s)&.truncate(DETAIL_LIMIT),
        **attributes.except(:arguments, :detail)
      )
    end

    def actor(grant)
      return { actor: "nobody" } if grant.nil?
      return { actor: "agent" } if grant.agent?

      claims = grant.claims
      client = claims.client_id.presence
      subject = claims.subject.presence

      if subject.nil? || subject == client
        { actor: "client", actor_name: client }
      else
        { actor: "person", actor_name: claims["name"].presence || claims["preferred_username"].presence || subject,
          via: client }
      end
    end

    def summarize(arguments, depth: 0)
      return {} unless arguments.is_a?(Hash)

      arguments.each_with_object({}) do |(key, value), held|
        held[key.to_s] = REDACTED.match?(key.to_s) ? "[redacted]" : shorten(value, depth)
      end
    end

    private

      def shorten(value, depth)
        case value
        when Hash then depth.zero? ? summarize(value, depth: 1) : "{#{value.size} keys}"
        when Array then "[#{value.size} items]"
        when String then Redaction.scrub(value).truncate(VALUE_LIMIT)
        when Numeric, TrueClass, FalseClass, NilClass then value
        else Redaction.scrub(value.to_s).truncate(VALUE_LIMIT)
        end
      end
  end
end
