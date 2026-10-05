issuer = ENV.fetch("DELEGATION_ISSUER")
server = ENV.fetch("DELEGATION_SERVER")
password = ENV.fetch("DELEGATION_PASSWORD")
people = ENV.fetch("DELEGATION_PEOPLE").split(",")
tenant = Masks::Server::Tenant.find_by!(subdomain: ENV.fetch("DELEGATION_TENANT"))

Masks::Server::Tenant.switch(tenant) do
  Masks::Server::Current.set(tenant: tenant, origin: issuer) do
    Masks::Server::Provider.find_by(key: "stand-in")&.destroy!

    provider = Masks::Server::Provider.new(key: "stand-in", name: "Stand-in MCP", protocol: "mcp",
                                           resource_url: "#{server}/mcp")
    provider.register!(callback: provider.callback_url)
    provider.save!
    puts "registered with the stand-in as #{provider.client_id}"

    granted = %w[openid profile email offline_access xixo:]

    people.each do |nickname|
      email = "#{nickname}@example.test"
      person = Masks::Server::Actor.locate(email) ||
               Masks::Server::Actor.invite!(email: email, nickname: nickname, scopes: granted.join(" "))
      person.update!(scopes: (person.scopes.split.reject { |scope| scope.end_with?(":") } | granted).join(" "))
      person.activate!(password, verifying_email: true)
      puts "#{email} can sign in"
    end
  end
end
