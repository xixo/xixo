$stdout.sync = true

require "yaml"

ROOT = Rails.root.join("test/fixtures/asks")
SUBDOMAIN = ENV.fetch("ASKS_TENANT", "asks")
MODELS_FROM = ENV.fetch("ASKS_MODELS_FROM", "uris")
WAIT = (ENV["ASKS_TIMEOUT"].presence || "900").to_i
NEAR = 60

def regex(text)
  match = text.match(%r{\A/(.*)/([imx]*)\z}m)
  return nil if match.nil?

  flags = match[2].chars.sum { |flag| { "i" => Regexp::IGNORECASE, "m" => Regexp::MULTILINE, "x" => Regexp::EXTENDED }[flag] }
  Regexp.new(match[1], flags)
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
  wanted.is_a?(Hash) ? "#{wanted['near'].join(' near ')}" : wanted.to_s
end

def settle(seconds)
  deadline = Time.current + seconds

  loop do
    yield.then { |pending| return pending if pending.empty? || Time.current > deadline }
    sleep 2
  end
end

source = Tenant.find_by(subdomain: MODELS_FROM) || abort("no tenant '#{MODELS_FROM}' to take the model backend from")
backend = Tenant.switch(source) { Resource.for_role(Resource::OpenaiCompatible::AGENT_ROLE) } ||
          abort("'#{MODELS_FROM}' has no model backend serving the agent role")
details = backend.details

tenant = Tenant.find_by(subdomain: SUBDOMAIN) || Tenant.create!(subdomain: SUBDOMAIN, name: "Asks")
paths = Pathname.glob(ROOT.join("files/*")).reject(&:directory?).sort
cases = YAML.load_file(ROOT.join("cases.yml"))
only = ENV["ASKS_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?)
cases = cases.select { |held| only.include?(held["id"]) } if only.any?

abort "no cases match #{only.join(', ')}" if cases.empty?

keys = Tenant.switch(tenant) do
  if ENV["ASKS_FRESH"].present?
    puts "forgetting everything #{SUBDOMAIN} held"
    Feed.destroy_all
  else
    Feed.where(type: Feed::NOTE).destroy_all
  end

  storage = Resource.default_storage || Resource::Database.create!(key: "disk", name: "Storage").tap(&:make_default_storage!)
  held = Resource::OpenaiCompatible.find_by(key: "ollama")
  if held.nil?
    Resource::OpenaiCompatible.create!(key: "ollama", details: details).make_default_inference!
  elsif held.details != details
    held.update!(details: details)
  end

  paths.map { |path| "asks/#{path.basename}".tap { |key| storage.upload(key, path.binread) } }
    .tap { SyncResourceJob.perform_now(tenant.id, storage.id) }
end

started = Time.current
puts "#{keys.size} file(s) in #{SUBDOMAIN}, waiting for analysis"

pending = settle(ENV.fetch("ASKS_INDEX_TIMEOUT", "1800").to_i) do
  Tenant.switch(tenant) do
    Reference.where(locator_key: keys).select { |held| held.analyzed_at.nil? || held.feed.analyses.open.exists? }
             .map(&:locator_key)
  end
end
abort "still analyzing: #{pending.join(', ')}" if pending.any?

Tenant.switch(tenant) do
  nil while Passage.sweep!.positive?
  nil while Embedding.sweep!.positive?
end
SearchIndex.refresh!
PassageIndex.refresh!

indexing = (Time.current - started).round
puts "indexed in #{indexing}s\n\n"

results = cases.map do |held|
  turns = []
  feed = nil

  held["turns"].each do |turn|
    asked_at = Time.current
    analysis = Tenant.switch(tenant) do
      feed ||= Feed.create!(type: Feed::NOTE, key: turn["ask"])
      feed.ask!(turn["ask"])
    end

    settle(WAIT) { Tenant.switch(tenant) { analysis.reload.open? ? [ analysis.id ] : [] } }

    said, calls, verified, status = Tenant.switch(tenant) do
      analysis.reload
      [ analysis.step_result("text").to_s.presence || analysis.step_result("answer").to_h["said"].to_s,
        Array(analysis.turns).size, analysis.step_result("verified").to_h["score"], analysis.status ]
    end

    missed = Array(turn["expect"]).reject { |wanted| matched?(said, wanted) }.map { |wanted| told(wanted) }
    wrong = Array(turn["reject"]).select { |wanted| matched?(said, wanted) }.map { |wanted| told(wanted) }
    passed = status == "done" && missed.empty? && wrong.empty?

    turns << { "ask" => turn["ask"], "said" => said, "passed" => passed, "missed" => missed, "wrong" => wrong,
               "status" => status, "seconds" => (Time.current - asked_at).round, "calls" => calls,
               "verified" => verified, "analysis" => analysis.id }

    puts "#{passed ? 'PASS' : 'FAIL'}  #{held['id']}: #{turn['ask']}  (#{turns.last['seconds']}s, #{calls} calls)"
    unless passed
      puts "      status #{status}" unless status == "done"
      puts "      missing #{missed.join(', ')}" if missed.any?
      puts "      said what it should not: #{wrong.join(', ')}" if wrong.any?
      puts "      said: #{said.squish.truncate(400)}"
    end
  end

  Tenant.switch(tenant) { feed&.destroy } unless ENV["ASKS_KEEP"].present?

  { "id" => held["id"], "turns" => turns }
end

asked = results.flat_map { |held| held["turns"] }
passed = asked.count { |turn| turn["passed"] }
seconds = asked.sum { |turn| turn["seconds"] }
calls = asked.sum { |turn| turn["calls"] }

run = {
  "at" => Time.current.iso8601, "commit" => `git rev-parse --short HEAD 2>/dev/null`.strip.presence,
  "models" => details["models"], "indexing_seconds" => indexing,
  "passed" => passed, "asked" => asked.size, "seconds" => seconds, "calls" => calls, "cases" => results
}

out = Rails.root.join("tmp/asks")
FileUtils.mkdir_p(out)
path = out.join("#{Time.current.strftime('%Y%m%d-%H%M%S')}.json")
File.write(path, JSON.pretty_generate(run))

puts "\n#{passed}/#{asked.size} passed, #{seconds}s and #{calls} model calls asking, #{indexing}s indexing"
puts "written to #{path.relative_path_from(Rails.root)}"

against = ENV["ASKS_AGAINST"].presence
if against
  before = JSON.parse(File.read(Rails.root.join(against)))
  was = before["cases"].flat_map { |held| held["turns"].map { |turn| [ [ held["id"], turn["ask"] ], turn["passed"] ] } }.to_h
  now = results.flat_map { |held| held["turns"].map { |turn| [ [ held["id"], turn["ask"] ], turn["passed"] ] } }.to_h

  now.each do |key, held|
    next if was[key].nil? || was[key] == held

    puts "#{held ? 'fixed' : 'broke'}  #{key.join(': ')}"
  end
  puts "against #{against}: #{before['passed']}/#{before['asked']} then, #{passed}/#{asked.size} now"
end
