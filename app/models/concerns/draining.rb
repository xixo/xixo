module Draining
  private

    def drain(response, host, limit:, into: nil, started: nil, total: nil)
      held = into || +"".b
      seen = 0

      response.read_body do |chunk|
        seen += chunk.bytesize
        raise Resource::Failed, "#{key}: #{host} sent more than #{limit} bytes" if seen > limit

        held << chunk

        if total && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > total
          raise Resource::Failed, "#{key}: #{host} was still sending after #{total}s"
        end
      end

      response.body = held unless into
    end
end
