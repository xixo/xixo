class LinkUploadsController < ActionController::API
  def show
    held = Resource::Machine::Caller.from(request, path: request.path)
    return head(:unauthorized) if held&.machine.nil?

    response.headers["Cache-Control"] = "no-store"
    return part(held.machine) if params.key?(:from)

    exchange = LinkExchange.taken!(held.machine, params[:request])
    return head(:not_found) if exchange.nil?

    response.headers["Content-Type"] = "application/octet-stream"
    response.headers["Content-Length"] = exchange.received.to_s
    self.response_body = LinkExchange::Sending.new(exchange)
  end

  private

    def part(machine)
      exchange = LinkExchange.relayed(machine, params[:request])
      return head(:not_found) if exchange.nil?

      from = Integer(params[:from].to_s, 10)
      bytes = exchange.part!(from)
      return head(:no_content) if bytes.empty?

      send_data bytes, type: "application/octet-stream", disposition: "inline"
    rescue ArgumentError, LinkExchange::OutOfRange
      head(:range_not_satisfiable)
    end
end
