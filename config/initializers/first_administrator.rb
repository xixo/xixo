module FirstAdministrator
  def start
    tenant = Current.tenant
    params[:privilege] = "admin" if params[:privilege].blank? && tenant&.connected? && !tenant.administered?

    super
  end
end

Rails.application.config.to_prepare do
  Masks::Rails::SessionsController.prepend(FirstAdministrator)
end
