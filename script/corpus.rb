$stdout.sync = true

require "yaml"

ROOT = Rails.root.join("test/fixtures/corpus")
SUBDOMAIN = ENV["CORPUS_TENANT"].presence || "corpus"
MODELS_FROM = ENV["CORPUS_MODELS_FROM"].presence || "uris"
GROUP = ENV["CORPUS_GROUP"].to_s.strip
INDEX_WAIT = (ENV["CORPUS_TIMEOUT"].presence || "1800").to_i
ASK_WAIT = (ENV["CORPUS_ASK_TIMEOUT"].presence || "900").to_i
NEAR = 60

def regex(text)
  match = text.match(%r{\A/(.*)/([imx]*)\z}m)
  match && Regexp.new(match[1], match[2])
end

def matched?(said, wanted)
  return near?(said, *wanted["near"]) if wanted.is_a?(Hash)

  pattern = regex(wanted.to_s)
  pattern ? said.match?(pattern) : said.downcase.include?(wanted.to_s.downcase)
end

def near?(said, first, second)
  starts = ->(term) { said.to_enum(:scan, /(?<![\d.])#{Regexp.escape(term)}(?![\d.])/i).map { Regexp.last_match.begin(0) } }
  starts.call(first).product(starts.call(second)).any? { |a, b| (a - b).abs <= NEAR }
end

def told(wanted)
  wanted.is_a?(Hash) ? wanted["near"].join(" near ") : wanted.to_s
end

def settle(seconds)
  deadline = Time.current + seconds

  loop do
    pending = yield
    break pending if pending.empty? || Time.current > deadline

    sleep 2
  end
end

def calls_in(analyses)
  analyses.sum("jsonb_array_length(turns)")
end

source = Tenant.find_by(subdomain: MODELS_FROM) || abort("no tenant '#{MODELS_FROM}' to take the model backend from")
details = Tenant.switch(source) { Resource.for_role(Resource::OpenaiCompatible::AGENT_ROLE)&.details } ||
          abort("'#{MODELS_FROM}' has no model backend serving the agent role")

paths = Pathname.glob(ROOT.join(GROUP.presence || "*", "*")).reject(&:directory?).sort
abort "nothing to load under #{ROOT}/#{GROUP}" if paths.empty?

named = ENV["CORPUS_CASES"].to_s.split(",").map(&:strip).reject(&:empty?)
cases = YAML.load_file(ROOT.join("cases.yaml"))
cases = named.include?("none") ? [] : cases.select { |held| named.include?(held["id"]) } if named.any?
cases = [] if GROUP.present? && named.empty?

tenant = Tenant.find_by(subdomain: SUBDOMAIN) || Tenant.create!(subdomain: SUBDOMAIN, name: "Corpus")
reuse = ENV["CORPUS_REUSE"].present?
started = Time.current

storage, keys = Tenant.switch(tenant) do
  storage = Resource.default_storage ||
            Resource::Database.find_or_create_by!(key: "database") { |held| held.name = "Database" }.tap(&:make_default_storage!)

  inference = Resource::OpenaiCompatible.find_or_initialize_by(key: "ollama")
  fresh = inference.new_record?
  inference.update!(details: details)
  inference.make_default_inference! if fresh

  Feed.where(type: Feed::NOTE).destroy_all

  keys = paths.map { |path| "corpus/#{path.dirname.basename}/#{path.basename}" }
  stale = Feed.joins(:references).where(feed_references: { resource_id: storage.id, locator_key: keys }).distinct

  if reuse
    puts "reusing what #{SUBDOMAIN} already analyzed"
  elsif stale.exists?
    puts "clearing #{stale.count} feed(s) a previous run left behind"
    stale.destroy_all
  end

  paths.zip(keys).each { |path, key| storage.upload(key, path.binread) }
  SyncResourceJob.perform_now(tenant.id, storage.id)

  [ storage, keys ]
end

puts "#{keys.length} file(s) into #{SUBDOMAIN}, analyzing on #{details.dig('models', 'smart')}"

pending = settle(INDEX_WAIT) do
  Tenant.switch(tenant) do
    uploaded = Reference.where(resource: storage, locator_key: keys)
    uploaded.where(analyzed_at: nil).or(uploaded.where(feed_id: Analysis.open.select(:feed_id))).pluck(:locator_key)
  end
end

Tenant.switch(tenant) { nil while (Embedding.sweep! + Passage.sweep!).positive? }
SearchIndex.refresh!
PassageIndex.refresh!

indexing = (Time.current - started).round

files = Tenant.switch(tenant) do
  Reference.where(resource: storage, locator_key: keys).includes(:feed).order(:locator_key).map do |reference|
    analyses = reference.feed.analyses.where.not(cause: "ask")
    steps = reference.feed.analysis&.steps || {}
    spent = analyses.where.not(finished_at: nil).sum { |held| held.finished_at - held.created_at }.round
    calls = calls_in(analyses)

    puts "\n#{reference.locator_key} [#{reference.mime}] #{spent}s, #{calls} call(s)"

    summary = steps.dig("summary", "result") || {}
    if summary["summary"].present?
      puts "  #{summary['summary']}"
      puts "  tags: #{Array(summary['tags']).join(', ')}" if summary["tags"].present?
    elsif steps.key?("summary")
      puts "  no description: #{steps.dig('summary', 'error', 'message')}"
    else
      puts "  no summary step: nothing served the role, or there was nothing to ask about"
    end

    steps.except("summary").each do |name, step|
      next unless step.key?("error")

      puts "  #{name} failed: #{step.dig('error', 'message').to_s.split("\n").first}"
    end

    { "key" => reference.locator_key, "mime" => reference.mime, "seconds" => spent, "calls" => calls,
      "failed" => steps.select { |_, step| step.key?("error") }.keys, "tags" => reference.feed.tags.pluck(:key) }
  end
end

indexing_calls = files.sum { |file| file["calls"] }
puts "\nstill analyzing when the timeout ran out: #{pending.join(', ')}" if pending.any?
puts "\n#{files.size - pending.size}/#{keys.size} analyzed in #{indexing}s, #{indexing_calls} call(s) to a model"
puts "slowest: #{files.max_by(5) { |file| file['seconds'] }.map { |file| "#{file['key']} #{file['seconds']}s" }.join(', ')}"

puts "\nasking #{cases.size} case(s)\n\n" if cases.any?

results = cases.map do |held|
  turns = []
  feed = nil

  held["turns"].each do |turn|
    asked_at = Time.current
    analysis = Tenant.switch(tenant) do
      feed ||= Feed.create!(type: Feed::NOTE, key: turn["ask"])
      feed.ask!(turn["ask"])
    end

    settle(ASK_WAIT) { Tenant.switch(tenant) { [ analysis.reload ].select(&:open?) } }

    said, calls, status = Tenant.switch(tenant) do
      [ feed.conversation(through: analysis).last.said.to_s, Array(analysis.turns).size, analysis.status ]
    end

    missed = Array(turn["expect"]).reject { |wanted| matched?(said, wanted) }.map { |wanted| told(wanted) }
    wrong = Array(turn["reject"]).select { |wanted| matched?(said, wanted) }.map { |wanted| told(wanted) }
    passed = status == "done" && missed.empty? && wrong.empty?
    seconds = (Time.current - asked_at).round

    turns << { "ask" => turn["ask"], "said" => said, "passed" => passed, "missed" => missed, "wrong" => wrong,
               "status" => status, "seconds" => seconds, "calls" => calls, "analysis" => analysis.id }

    puts "#{passed ? 'PASS' : 'FAIL'}  #{held['id']}: #{turn['ask']}  (#{seconds}s, #{calls} calls)"
    next if passed

    puts "      status #{status}" unless status == "done"
    puts "      missing #{missed.join(', ')}" if missed.any?
    puts "      said what it should not: #{wrong.join(', ')}" if wrong.any?
    puts "      said: #{said.squish.truncate(400)}"
  end

  Tenant.switch(tenant) { feed&.destroy } unless ENV["CORPUS_KEEP"].present?

  { "id" => held["id"], "turns" => turns }
end

asked = results.flat_map { |held| held["turns"] }
passed = asked.count { |turn| turn["passed"] }
asking = asked.sum { |turn| turn["seconds"] }
asking_calls = asked.sum { |turn| turn["calls"] }

run = {
  "at" => Time.current.iso8601, "commit" => `git rev-parse --short HEAD 2>/dev/null`.strip.presence,
  "models" => details["models"], "group" => GROUP.presence, "reused" => reuse,
  "indexing" => { "seconds" => indexing, "calls" => indexing_calls, "files" => files },
  "asking" => { "passed" => passed, "asked" => asked.size, "seconds" => asking, "calls" => asking_calls,
                "cases" => results }
}

out = Rails.root.join("tmp/corpus")
FileUtils.mkdir_p(out)
path = out.join("#{Time.current.strftime('%Y%m%d-%H%M%S')}.json")
File.write(path, JSON.pretty_generate(run))

puts "\nindexing: #{keys.size} files in #{indexing}s, #{indexing_calls} model calls#{' (reused)' if reuse}"
if asked.any?
  puts "asking:   #{passed}/#{asked.size} right, #{asking}s, #{asking_calls} model calls, " \
       "#{(asking.to_f / asked.size).round}s an answer"
end
puts "written to #{path.relative_path_from(Rails.root)}"

against = ENV["CORPUS_AGAINST"].presence
if against
  before = JSON.parse(File.read(Rails.root.join(against)))
  outcomes = ->(listed) { listed.flat_map { |held| held["turns"].map { |turn| [ [ held["id"], turn["ask"] ], turn["passed"] ] } }.to_h }
  was = outcomes.call(before.dig("asking", "cases").to_a)

  outcomes.call(results).each do |key, passing|
    next if was[key].nil? || was[key] == passing

    puts "#{passing ? 'fixed' : 'broke'}  #{key.join(': ')}"
  end

  then_asked = before["asking"].to_h
  puts "against #{against}:"
  puts "  indexing #{before.dig('indexing', 'seconds')}s then, #{indexing}s now"
  puts "  asking #{then_asked['passed']}/#{then_asked['asked']} right in #{then_asked['seconds']}s then, " \
       "#{passed}/#{asked.size} in #{asking}s now"
end
