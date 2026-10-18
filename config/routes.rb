Rails.application.routes.draw do
  if Rails.env.development?
    mount GraphiQL::Rails::Engine, at: "/graphiql", graphql_path: "/graphql"
  end

  mount Masks::Rails::Engine, at: "/auth", as: :masks

  if EmbeddedIssuer.on?
    mount Masks::Server::Engine, at: EmbeddedIssuer::PATH

    EmbeddedIssuer::INSERTED.each { |path| get "#{path}#{EmbeddedIssuer::PATH}", to: EmbeddedIssuer.inserted }
  end

  post "/graphql", to: "graphql#execute"

  post "/uploads", to: "uploads#create"
  post "/share", to: "shares#create"

  get "/references/:id/content", to: "content#show", as: :reference_content

  get "/link/uploads/:request", to: "link_uploads#show", as: :link_upload
  get "/link.sh", to: "links#script", as: :link_script, format: false
  get "/link/download/xixo-link.service", to: "links#unit", as: :link_unit
  get "/link/download/xixo-link.plist", to: "links#plist", as: :link_plist
  get "/link/download/xixo-link-update.service", to: "links#update_unit", as: :link_update_unit
  get "/link/download/xixo-link-update.path", to: "links#update_path", as: :link_update_path
  get "/link/download/xixo-link-part@.service", to: "links#part_unit", as: :link_part_unit
  get "/link/download/xixo-link-part@.path", to: "links#part_path", as: :link_part_path
  get "/link/download/:file", to: "links#download", as: :link_download,
                              constraints: { file: /xixo-link-[a-z0-9]+-[a-z0-9]+|xixo-mac-reader/ }
  get "/link/builds", to: "links#builds", as: :link_builds
  post "/link/cli/device", to: "link_cli#device", as: :link_cli_device
  post "/link/cli/token", to: "link_cli#token", as: :link_cli_token
  post "/link/machines", to: "link_machines#create", as: :link_machines
  delete "/link/machines/:key", to: "link_machines#destroy", as: :link_machine, constraints: { key: /[a-z0-9][a-z0-9.-]*/ }
  post "/link/requests", to: "links#start", as: :link_requests
  post "/link/requests/token", to: "links#token", as: :link_request_token
  get "/link", to: "links#show", as: :link_status, constraints: ->(req) { req.authorization.present? }
  post "/link", to: "links#create", as: :link_up
  get "/resources/:id/connect", to: "resource_connections#show", as: :resource_connect
  get "/connect/callback", to: "resource_connections#callback", as: :resource_connect_callback

  get "/mcp", to: "mcp#stream"
  match "/mcp", to: "mcp#handle", via: %i[post delete]

  get "/.well-known/oauth-protected-resource", to: "oauth_metadata#protected_resource"
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth_metadata#protected_resource"

  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "health#show", as: :health

  root "home#index"

  get "*path", to: "home#index", constraints: ->(req) { !req.xhr? && req.format.html? }
end
