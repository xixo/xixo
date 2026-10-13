class Resource
  class Machine
    module Downloads
      BUILD = /\Axixo-link-(linux|darwin)-(amd64|arm64)\z/
      UNIT = "xixo-link.service".freeze
      PACKAGES = %w[
        ca-certificates libvips-tools libraw-bin libimage-exiftool-perl libarchive-zip-perl poppler-utils
        tesseract-ocr ffmpeg libreoffice-writer libreoffice-calc fonts-liberation
      ].freeze
      PLIST = "xixo-link.plist".freeze
      MAC_READER = "xixo-mac-reader".freeze
      RELEASES = "https://github.com/xixo/xixo/releases/download".freeze
      MANIFEST = ".release-please-manifest.json".freeze
      RELEASED = /\A\d+\.\d+\.\d+\z/

      Build = Data.define(:os, :arch, :file, :path) do
        def sha256 = Downloads.digest(path)
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

      def held(file)
        path = Machine.binaries + file
        path if File.lstat(path).file?
      rescue SystemCallError
        nil
      end

      def version
        held = JSON.parse(Rails.root.join(MANIFEST).read)["."].to_s
        held if held.match?(RELEASED)
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def mac_reader
        held = version
        "#{RELEASES}/server-v#{held}/#{MAC_READER}" if held
      end

      def digest(path)
        stat = File.lstat(path)
        @digests ||= {}
        @digests[[ path.to_s, stat.size, stat.mtime.to_f ]] ||= Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
