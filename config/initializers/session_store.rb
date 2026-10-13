Rails.application.config.session_store :cache_store,
                                       key: "_xixo_session",
                                       same_site: :lax,
                                       expire_after: 30.days
