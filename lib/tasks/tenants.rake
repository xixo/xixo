namespace :xixo do
  desc "Ensure every tenant named by XIXO_TENANT or XIXO_TENANTS exists"
  task tenants: :environment do
    Tenant.declare!.each { |tenant| puts "#{tenant.subdomain}: #{tenant.name}" }
  end
end
