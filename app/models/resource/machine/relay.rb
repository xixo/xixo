class Resource
  class Machine
    class Relay
      WINDOW = 32.megabytes
      STALLS_AFTER = 2.minutes
      SETTLES_WITHIN = 10.minutes
      POLLED_EVERY = 0.1
      MOVED_AT_ONCE = 64
      KEPT_ALIVE_EVERY = 1.minute

      def initialize(from:, folder:, path:, size:, to:, into:, target:, modified_at: nil, window: WINDOW, waiting: nil)
        @from = from
        @folder = folder
        @path = path
        @size = size
        @to = to
        @into = into
        @target = target
        @modified_at = modified_at
        @window = window
        @waiting = waiting || -> { sleep POLLED_EVERY }
      end

      def copy!
        LinkExchange.apart { ActiveRecord::Base.uncached { copied } }
      end

      private

        def copied
          @upload = @to.relayed_upload(@size)
          @write = @to.asking("write", {
            "folder" => @into, "path" => @target, "upload" => @upload.request, "size" => @size,
            "replace" => false, "relayed" => true, "modified_at" => @modified_at&.utc&.iso8601(6)
          }.compact)
          @moved_at = Time.current
          @base = 0
          offset = 0

          while offset < @size
            room!
            length = [ @window, @size - offset ].min
            poured(offset, length)
            offset += length
          end

          written
        ensure
          forget(@upload, @write, @read)
        end

        def room!
          until @upload.waiting * MOST_CHUNKED <= @window
            watched!
            waited!("#{@to.key} stopped taking #{@target}")
          end
        end

        def poured(offset, length)
          whole = offset.zero? && length == @size
          asked = { "folder" => @folder, "path" => @path }
          asked = asked.merge("offset" => offset, "length" => length) unless whole
          @read = @from.asking("read", asked)
          moved = 0
          taken = 0

          loop do
            rows = waiting_in(@read, taken)

            if rows.any?
              LinkChunk.where(id: rows.map(&:first)).update_all([ "link_exchange_id = ?, seq = seq + ?", @upload.id, @base ])
              moved += rows.sum(&:last)
              taken += rows.size
              @moved_at = Time.current
              raise Resource::Failed, "#{@from.key}: xixo link sent more of #{@path} than xixo asked for" if moved > length

              next
            end

            held = fresh(@read)
            raise Refusal, "#{@from.key}: xixo link said #{held.error}" if held.refused?
            break if held.answered? && moved == length && read_as_asked?(held.result, offset, length, whole)

            watched!
            waited!("#{@from.key} stopped sending #{@path}")
          end

          @base += taken
          forget(@read)
          @read = nil
        end

        def read_as_asked?(said, offset, length, whole)
          said = said.to_h
          return true if said["size"] == length && (whole || said["offset"] == offset)

          raise Resource::Failed, "#{@from.key}: xixo link sent a part of #{@path} xixo did not ask for. It may need an update"
        end

        def written
          settles_by = nil

          loop do
            held = fresh(@write)
            raise Refusal, "#{@to.key}: xixo link said #{held.error}" if held.refused?
            return finished(held.result) if held.answered?

            sent = fresh(@upload).sent
            if sent == @size
              settles_by ||= SETTLES_WITHIN.from_now
              raise Resource::Failed, "#{@to.key}: xixo link took #{@target} and did not say it was written" if Time.current > settles_by
            elsif sent != @sent
              @sent = sent
              @moved_at = Time.current
            end

            waited!("#{@to.key} stopped taking #{@target}") unless settles_by
            @waiting.call if settles_by
          end
        end

        def finished(said)
          said = said.to_h
          return said if said["size"] == @size

          raise Resource::Failed, "#{@to.key}: xixo link wrote #{said['size'].inspect} bytes of #{@target}, not #{@size}"
        end

        def waiting_in(exchange, from)
          rows = LinkChunk.where(link_exchange_id: exchange.id, seq: from...(from + MOVED_AT_ONCE))
                          .order(:seq).pluck(:id, :seq, Arel.sql("octet_length(bytes)"))

          rows.each_with_index.take_while { |(_, seq, _), index| seq == from + index }.map(&:first)
        end

        def watched!
          held = fresh(@write)
          raise Refusal, "#{@to.key}: xixo link said #{held.error}" if held.refused?

          sent = fresh(@upload).sent
          return if sent == @sent

          @sent = sent
          @moved_at = Time.current
        end

        def waited!(stalled)
          raise Resource::Failed, "#{stalled} for #{STALLS_AFTER.inspect}" if Time.current - @moved_at > STALLS_AFTER

          kept_alive!
          @waiting.call
        end

        def kept_alive!
          return if @kept_at && @kept_at > KEPT_ALIVE_EVERY.ago

          @kept_at = Time.current
          LinkExchange.where(id: [ @upload, @write ].compact.map(&:id)).update_all(updated_at: @kept_at)
        end

        def fresh(exchange)
          LinkExchange.uncached { LinkExchange.find_by(id: exchange.id) } ||
            raise(Resource::Failed, "xixo forgot the exchange that carried #{@path}")
        end

        def forget(*exchanges)
          ids = exchanges.compact.map(&:id)
          LinkExchange.where(id: ids).delete_all if ids.any?
        end
    end
  end
end
