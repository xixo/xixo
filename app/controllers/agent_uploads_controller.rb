class AgentUploadsController < ActionController::API
  def show
    held = Resource::XixoAgent::Caller.from(request, path: request.path)
    return head(:unauthorized) if held.nil?

    exchange = AgentExchange.taken!(held.agent, params[:request])
    return head(:not_found) if exchange.nil?

    response.headers["Content-Type"] = "application/octet-stream"
    response.headers["Content-Length"] = exchange.received.to_s
    response.headers["Cache-Control"] = "no-store"
    self.response_body = AgentExchange::Sending.new(exchange)
  end
end
