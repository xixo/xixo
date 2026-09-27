threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

plugin :tmp_restart

require_relative "../lib/switch"

plugin :solid_queue if Switch.on?("SOLID_QUEUE_IN_PUMA")

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
