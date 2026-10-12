module FirstAdministrator
  def start
    tenant = Tenant.resolve(request.host)
    params[:privilege] = "admin" if params[:privilege].blank? && tenant&.connected? && !tenant.administered?

    super
  end
end

Rails.application.config.to_prepare do
  Masks::Rails::SessionsController.prepend(FirstAdministrator)
end
