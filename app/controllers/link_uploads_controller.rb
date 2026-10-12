class LinkUploadsController < ActionController::API
  def show
    held = Resource::Machine::Caller.from(request, path: request.path)
    return head(:unauthorized) if held&.machine.nil?

    exchange = LinkExchange.taken!(held.machine, params[:request])
    return head(:not_found) if exchange.nil?

    response.headers["Content-Type"] = "application/octet-stream"
    response.headers["Content-Length"] = exchange.received.to_s
    response.headers["Cache-Control"] = "no-store"
    self.response_body = LinkExchange::Sending.new(exchange)
  end
end
