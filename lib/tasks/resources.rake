namespace :xixo do
  desc "Restate what every resource serves, then reconcile every one config/resources.yml declares, in every tenant"
  task resources: :environment do
    Tenant.find_each { |tenant| Tenant.switch(tenant) { Resource.restate! } }

    Tenant.find_each do |tenant|
      Tenant.switch(tenant) do
        Resource.declare!.each { |resource| puts "#{tenant.subdomain}: #{resource.key}" }
      end
    end
  end
end
