Rails.application.routes.draw do
  if Rails.env.development?
    mount GraphiQL::Rails::Engine, at: "/graphiql", graphql_path: "/graphql"
  end

  mount Masks::Rails::Engine, at: "/auth", as: :masks

  post "/graphql", to: "graphql#execute"

  post "/uploads", to: "uploads#create"
  post "/share", to: "shares#create"

  get "/references/:id/content", to: "content#show", as: :reference_content

  get "/link/uploads/:request", to: "link_uploads#show", as: :link_upload
  get "/link/download/xixo-link.service", to: "links#unit", as: :link_unit
  get "/link/download/xixo-link.plist", to: "links#plist", as: :link_plist
  get "/link/download/:file", to: "links#download", as: :link_download, constraints: { file: /xixo-link-[a-z0-9]+-[a-z0-9]+/ }
  post "/link", to: "links#create", as: :link_up
  get "/resources/:id/connect", to: "resource_connections#show", as: :resource_connect
  get "/connect/callback", to: "resource_connections#callback", as: :resource_connect_callback

  match "/mcp", to: "mcp#handle", via: %i[get post delete]

  get "/.well-known/oauth-protected-resource", to: "oauth_metadata#protected_resource"
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth_metadata#protected_resource"

  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "health#show", as: :health

  root "home#index"

  get "*path", to: "home#index", constraints: ->(req) { !req.xhr? && req.format.html? }
end
