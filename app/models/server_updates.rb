class ServerUpdates
  ACTIONS = %w[update_now pause resume roll_back channel].freeze
  CHANNELS = %w[main releases].freeze
  MOST_STATUS = 1.megabyte
  MOST_EVENTS = 1.megabyte
  SHOWN_EVENTS = 10

  class Refused < StandardError; end

  class << self
    def state = ENV.fetch("XIXO_UPDATES_STATE", "/var/lib/xixo-updates/state")
    def request_path = ENV.fetch("XIXO_UPDATES_REQUEST", "/run/xixo-updates/requests/request.json")

    def controlled_by?(tenant)
      named = ENV["XIXO_UPDATES_TENANT"].presence || Rails.configuration.xixo.tenant
      named.present? && tenant&.subdomain == named
    end

    def status
      held = JSON.parse(limited(File.join(state, "status.json"), MOST_STATUS))
      held.is_a?(Hash) ? held : nil
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      nil
    end

    def events(limit = SHOWN_EVENTS)
      limited(File.join(state, "events.jsonl"), MOST_EVENTS, tail: true).lines.last(limit).reverse.filter_map do |line|
        held = JSON.parse(line)
        held if held.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    rescue Errno::ENOENT, Errno::EACCES
      []
    end

    def request!(action:, by:, channel: nil)
      raise Refused, "#{action.inspect} is not something the updater does" unless ACTIONS.include?(action)
      raise Refused, "name main or releases" if action == "channel" && !CHANNELS.include?(channel)

      asked = { "action" => action, "channel" => (channel if action == "channel"), "at" => Time.current.utc.iso8601(6),
                "by" => by.to_s.scrub.first(200) }.compact
      written(request_path, JSON.generate(asked))
    rescue Errno::ENOENT, Errno::EACCES, Errno::EROFS
      raise Refused, "xixo cannot reach the updater on this server, so updates are manual"
    end

    private

      def limited(path, most, tail: false)
        File.open(path, "rb") do |file|
          file.seek([ file.size - most, 0 ].max) if tail
          file.read(most).to_s.force_encoding(Encoding::UTF_8).scrub
        end
      end

      def written(path, body)
        temporary = "#{path}.#{SecureRandom.hex(6)}"
        File.write(temporary, body, perm: 0o644)
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
      end
  end
end
