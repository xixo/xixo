class Resource
  class Machine
    module Downloads
      BUILD = /\Axixo-link-(linux|darwin)-(amd64|arm64)\z/
      UNIT = "xixo-link.service".freeze
      UPDATE_UNIT = "xixo-link-update.service".freeze
      UPDATE_PATH = "xixo-link-update.path".freeze
      PART_UNIT = "xixo-link-part@.service".freeze
      PART_PATH = "xixo-link-part@.path".freeze
      PACKAGES = %w[
        ca-certificates libvips-tools libraw-bin libimage-exiftool-perl libarchive-zip-perl poppler-utils
        tesseract-ocr ffmpeg libreoffice-writer libreoffice-calc fonts-liberation
      ].freeze
      PLIST = "xixo-link.plist".freeze
      RELEASE = "release.json".freeze
      BUNDLE = "release.sigstore.json".freeze
      MAC_READER = "xixo-mac-reader".freeze
      MAC_DIR = "mac".freeze
      RELEASES = "https://github.com/xixo/xixo/releases/download".freeze
      MANIFEST = ".release-please-manifest.json".freeze
      RELEASED = /\A\d+\.\d+\.\d+(\+[0-9a-f]{7,40})?\z/
      VERSION = "version".freeze
      FILES = (%w[linux darwin].product(%w[amd64 arm64]).map { |os, arch| "xixo-link-#{os}-#{arch}" } + [ MAC_READER ]).freeze

      Build = Data.define(:os, :arch, :file, :path) do
        def sha256 = Downloads.digest(path)
        def name = file == MAC_READER ? MAC_READER : "xixo-link"
      end

      module_function

      def builds
        Dir.children(Machine.binaries.to_s).sort.filter_map do |file|
          matched = file.match(BUILD)
          next unless matched

          path = binary(file)
          Build.new(os: matched[1], arch: matched[2], file: file, path: path) if path
        end
      rescue SystemCallError
        []
      end

      def served(file)
        return mac_reader_build if file.to_s == MAC_READER

        builds.find { |held| held.file == file.to_s }
      end

      def build_for(os, arch)
        builds.find { |held| held.os == os.to_s && held.arch == arch.to_s }
      end

      def mac_reader_build
        path = Machine.binaries + MAC_DIR + MAC_READER
        Build.new(os: "darwin", arch: "universal", file: MAC_READER, path: path) if File.lstat(path).file?
      rescue SystemCallError
        nil
      end

      def binary(file)
        return nil unless file.to_s.match?(BUILD)

        path = Machine.binaries + file.to_s
        path if File.lstat(path).file?
      rescue SystemCallError
        nil
      end

      def plist
        held(PLIST)
      end

      def unit
        held(UNIT)
      end

      def update_unit
        held(UPDATE_UNIT)
      end

      def update_path
        held(UPDATE_PATH)
      end

      def part_unit
        held(PART_UNIT)
      end

      def part_path
        held(PART_PATH)
      end

      def release_file
        held(RELEASE)
      end

      def bundle_file
        held(BUNDLE)
      end

      def signed
        path = release_file
        return unless path && bundle_file

        serial = JSON.parse(File.read(path, 1.megabyte))["serial"]
        { "release" => digest(path), "serial" => serial } if serial.is_a?(Integer) && serial.positive?
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def held(file)
        path = Machine.binaries + file
        path if File.lstat(path).file?
      rescue SystemCallError
        nil
      end

      def version
        built || manifest
      end

      def built
        held = Machine.binaries.join(VERSION).read.strip
        held if held.match?(RELEASED)
      rescue SystemCallError
        nil
      end

      def manifest
        held = JSON.parse(Rails.root.join(MANIFEST).read)["."].to_s
        held if held.match?(RELEASED)
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def mac_reader
        held = version
        "#{RELEASES}/server-v#{numbered(held)}/#{MAC_READER}" if held
      end

      def released?(value)
        value.to_s.match?(RELEASED)
      end

      def numbered(version)
        version.to_s.split("+").first
      end

      def digest(path)
        stat = File.lstat(path)
        @digests ||= {}
        @digests[[ path.to_s, stat.size, stat.mtime.to_f ]] ||= Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
