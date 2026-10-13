class PublicCache
  HASHED = "public, max-age=#{1.year.to_i}, immutable".freeze
  REVALIDATED = "no-cache".freeze
  ALWAYS_REVALIDATED = %w[/sw.js].freeze

  def initialize(app, hashed_prefix: "/#{ViteRuby.config.public_output_dir}/assets/")
    @app = app
    @hashed_prefix = hashed_prefix
  end

  def call(env)
    status, headers, body = @app.call(env)
    return [ status, headers, body ] unless status == 200 && env["REQUEST_METHOD"].in?(%w[GET HEAD])

    path = env["PATH_INFO"].to_s
    if path.start_with?(@hashed_prefix)
      headers["cache-control"] = HASHED
    elsif ALWAYS_REVALIDATED.include?(path)
      headers["cache-control"] = REVALIDATED
    end

    [ status, headers, body ]
  end
end
