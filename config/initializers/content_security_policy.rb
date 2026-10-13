Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :none
    policy.object_src :none
    policy.frame_ancestors :none
    policy.script_src :self
    policy.style_src :self, :unsafe_inline
    policy.img_src :self, :data, :blob, -> { Tenant.issuer_origin(is_a?(ActionDispatch::Request) ? self : request) }
    policy.media_src :self, :blob
    policy.font_src :self, :data
    policy.connect_src :self
    policy.connect_src :self, :ws if Rails.env.development?
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
