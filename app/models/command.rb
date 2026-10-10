module Command
  class Stopped < StandardError; end

  SECONDS = 600
  MEMORY = 4.gigabytes

  def self.capture(*args, env: {}, seconds: SECONDS, memory: MEMORY, binary: false)
    Open3.popen3(env, *args, pgroup: true, rlimit_data: memory) do |stdin, stdout, stderr, waiter|
      stdin.close
      stdout.binmode if binary
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }

      unless waiter.join(seconds)
        stop(waiter.pid)
        [ out, err ].each(&:kill)
        raise Stopped, "#{File.basename(args.first.to_s)} ran past #{seconds} seconds and was stopped"
      end

      [ out.value, err.value, waiter.value ]
    end
  end

  def self.stop(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end
end
