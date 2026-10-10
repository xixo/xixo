require "open3"

class Raw
  class Unreadable < StandardError; end

  MINIMUM = 1024

  def self.preview(path)
    made = viewable(path)

    begin
      yield made
    ensure
      File.unlink(made) if File.exist?(made)
    end
  end

  def self.viewable(path)
    carried = embedded(path)

    return carried if carried && wide_enough?(carried)

    File.unlink(carried) if carried

    developed(path) ||
      raise(Unreadable, "#{File.basename(path)} carries no image simple_dcraw could read")
  end

  def self.embedded(path)
    run("-e", path)

    Dir["#{path}.thumb.*"].first
  end

  def self.developed(path)
    run("-T", path)

    Dir["#{path}.tiff"].first
  end

  def self.wide_enough?(made)
    stdout, _stderr, status = Command.capture("vipsheader", "-f", "width", made)

    status.success? && stdout.strip.to_i >= MINIMUM
  end

  def self.run(flag, path)
    _stdout, stderr, status = Command.capture("simple_dcraw", flag, path)

    raise Unreadable, "simple_dcraw #{flag}: #{stderr.truncate(200)}" unless status.success?
  rescue Command::Stopped => e
    raise Unreadable, e.message
  end

  private_class_method :viewable, :embedded, :developed, :wide_enough?, :run
end
