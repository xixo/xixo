module ReferencePages
  class Environment
    PAGE = "docs/src/content/docs/reference/environment.mdx".freeze

    RUBY = /(?:ENV(?:\.fetch)?[\[(]|Switch\.on\?\()\s*["']([A-Z][A-Z0-9_]*)["']/
    SHELL = /\$\{?([A-Z][A-Z0-9_]*)/
    NODE = /process\.env\.([A-Z][A-Z0-9_]*)/

    SOURCES = [
      [ %w[app config lib db/seeds.rb Gemfile dev test/test_helper.rb], RUBY ],
      [ %w[bin/docker-entrypoint compose.yml compose.multi.yml], SHELL ],
      [ %w[vite.config.ts docs/astro.config.mjs], NODE ]
    ].freeze

    SKIPPED = %w[lib/reference_pages].freeze
    INTERNAL = %w[PATH BUNDLE_GEMFILE HOME SHELL].freeze

    DEPENDENCIES = %w[
      SECRET_KEY_BASE
      SECRET_KEY_BASE_DUMMY
      RAILS_ENV
      WEB_CONCURRENCY
      HTTP_PORT
      TARGET_PORT
      TLS_DOMAIN
      VITE_RUBY_HOST
      VITE_RUBY_SKIP_PROXY
    ].freeze

    def drift
      found = read
      shown = listed

      unlisted = found.except(*shown).map { |name, path| "#{name} is read by #{path} and missing from #{PAGE}" }
      unread = (shown - found.keys - DEPENDENCIES).map { |name| "#{name} is listed in #{PAGE} and read by nothing" }

      unlisted + unread
    end

    private

      def read
        SOURCES.each_with_object({}) do |(roots, pattern), held|
          roots.flat_map { |root| files(root) }.each do |path|
            relative = path.relative_path_from(Rails.root).to_s

            path.read.scan(pattern).flatten.each { |name| held[name] ||= relative unless INTERNAL.include?(name) }
          end
        end.sort.to_h
      end

      def listed
        Rails.root.join(PAGE).read.scan(/^\| `([A-Z][A-Z0-9_]*)` \|/).flatten.uniq
      end

      def files(root)
        path = Rails.root.join(root)
        found = path.directory? ? Pathname.glob(path.join("**/*.{rb,yml,erb,rake}")) : [ path ]

        found.select(&:file?).reject { |file| SKIPPED.any? { |skip| file.to_s.include?(skip) } }
      end
  end
end
