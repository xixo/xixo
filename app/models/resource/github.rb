class Resource
  class Github < Api
    API = "https://api.github.com".freeze
    VERSION = "2022-11-28".freeze
    REPO = %r{\A[\w.-]+/[\w.-]+\z}
    COMMENTS = 50
    SKEW = 5.minutes

    def self.api
      API
    end

    def self.service
      "GitHub"
    end

    def self.attaching
      {
        label: "GitHub",
        blurb: "Issues and pull requests from the repositories you name, each one an item with " \
               "its body and its discussion.",
        names: "A name for it",
        fields: [
          token_field("Access token",
                      help: "A personal access token with read access to the repositories below.",
                      placeholder: "github_pat_…"),
          field("repos", "Repositories", required: true,
                help: "One owner/name per line, or separated by commas.",
                placeholder: "rails/rails"),
          field("state", "Which ones", help: "open, closed, or all. all by default.",
                placeholder: "all")
        ]
      }
    end

    def self.command_schema
      {
        list: { repo: "string?", limit: "integer?" },
        get: { key: "string" },
        keep: { key: "string" }
      }
    end

    validate :it_names_a_repository

    def repos
      details["repos"].to_s.split(/[\s,]+/).filter_map { |held| held.strip.presence }
    end

    def state
      held = details["state"].to_s.downcase

      %w[open closed all].include?(held) ? held : "all"
    end

    def check!
      login = api_get("/user")["login"]

      raise Resource::Unusable, "#{key}: the token names no account" if login.blank?

      unreadable = repos.reject { |repo| readable?(repo) }

      if unreadable.any?
        raise Resource::Unusable,
              "#{key}: #{login} cannot read #{unreadable.to_sentence} — check the token's " \
              "repository access, not only its scopes"
      end

      true
    end

    def self.walks_changes?
      true
    end

    def each_page(cursor: nil, prefix: nil, walk: nil)
      wanted = repos
      repo, page = resume(cursor, wanted)
      since = walk&.since.to_h["updated"]
      walk&.reached({ "updated" => SKEW.ago.utc.iso8601 }, first: true)

      wanted.drop(wanted.index(repo).to_i).each do |held|
        loop do
          batch = issues(held, page, since: since)
          break if batch.empty?

          yield batch, "#{held}##{page}"
          break if batch.length < PAGE

          page += 1
        end

        page = 1
      end
    end

    def object_for(named)
      repo, number = split(named)
      held = held_repo(repo)

      raise ArgumentError, "#{named} names no issue number" unless number.to_s.match?(/\A\d+\z/)

      issue = api_get("/repos/#{held}/issues/#{number}").merge("repo" => held)

      unless state == "all" || issue["state"] == state
        raise ArgumentError, "#{key}: #{named} is #{issue['state']}, and it reads only #{state} ones"
      end

      issue
    end

    def locator_for(issue)
      {
        "repo" => issue.fetch("repo"),
        "number" => issue["number"],
        "url" => issue["html_url"],
        "state" => issue["state"],
        "shape" => issue["pull_request"] ? "pull" : "issue",
        "updated_at" => issue["updated_at"],
        "comments" => issue["comments"]
      }
    end

    def locator_key_for(issue)
      return issue.to_s unless issue.is_a?(Hash)

      "#{issue.fetch('repo')}/#{issue['pull_request'] ? 'pull' : 'issues'}/#{issue['number']}"
    end

    def version_for(locator)
      locator.to_h["updated_at"].presence
    end

    def mime_for(_issue)
      "text/markdown"
    end

    def title_for(issue)
      "#{issue.fetch('repo')}##{issue['number']} #{issue['title']}".strip
    end

    def download(locator)
      repo = locator.fetch("repo")
      number = locator.fetch("number")
      issue = api_get("/repos/#{repo}/issues/#{number}")
      said = comments(repo, number, locator["comments"])
      total = issue["comments"].to_i

      dropped!("comments", "read #{said.size} of #{total.to_fs(:delimited)}") if total > said.size

      StringIO.new(written(repo, issue, said))
    end

    def command_list(repo: nil, limit: nil)
      wanted = repo.present? ? held_repo(repo) : repos.first
      count = (limit || 30).to_i.clamp(1, PAGE)

      {
        "repo" => wanted,
        "issues" => issues(wanted, 1).first(count).map { |issue| described(issue) }
      }
    end

    def command_keep(key:) = kept(key)

    def command_get(key:)
      issue = object_for(key)
      repo = issue.fetch("repo")

      described(issue).merge("text" => written(repo, issue, comments(repo, issue["number"])))
    end

    private

      def headers
        super.merge(
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => VERSION
        )
      end

      def held_repo(named)
        repos.find { |listed| listed.casecmp?(named.to_s) } ||
          raise(ArgumentError, "#{key}: #{named} is not one of the repositories it reads")
      end

      def readable?(repo)
        api_get("/repos/#{repo}")["full_name"].present?
      rescue Api::Gone
        false
      end

      def resume(cursor, wanted)
        return [ wanted.first, 1 ] if cursor.blank?

        repo, page = cursor.to_s.split("#")

        return [ wanted.first, 1 ] unless wanted.include?(repo)

        [ repo, page.to_i + 1 ]
      end

      def issues(repo, page, since: nil)
        raise Resource::Unusable, "#{key}: names no repository to read" if repo.blank?

        found = api_get("/repos/#{repo}/issues",
                        state: state, per_page: PAGE, page: page,
                        sort: "updated", direction: "desc", since: since)

        Array(found).map { |issue| issue.merge("repo" => repo) }
      end

      # The locator counted them at sync, and an issue nobody replied to is most of them.
      def comments(repo, number, held = nil)
        return [] if held&.zero?

        api_get("/repos/#{repo}/issues/#{number}/comments", per_page: COMMENTS)
      rescue Api::Gone
        []
      end

      def written(repo, issue, comments)
        said = Array(comments).map do |comment|
          "#{comment.dig('user', 'login')} said:\n#{comment['body']}"
        end

        flattened("#{repo}##{issue['number']} #{issue['title']}",
                  "opened by #{issue.dig('user', 'login')}, #{issue['state']}",
                  issue["body"], said)
      end

      def described(issue)
        {
          "key" => locator_key_for(issue),
          "number" => issue["number"],
          "title" => issue["title"],
          "state" => issue["state"],
          "url" => issue["html_url"],
          "updated_at" => issue["updated_at"],
          "comments" => issue["comments"]
        }
      end

      def split(key)
        parts = key.to_s.split("/")

        raise ArgumentError, "#{key} is not owner/name/issues/number" if parts.length < 4

        [ parts.first(2).join("/"), parts[3] ]
      end

      def it_names_a_repository
        return errors.add(:details, "must name at least one repository") if repos.empty?

        wrong = repos.reject { |repo| repo.match?(REPO) }

        errors.add(:details, "#{wrong.to_sentence} is not owner/name") if wrong.any?
      end
  end
end
