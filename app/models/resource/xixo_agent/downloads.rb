class Resource
  class XixoAgent
    module Downloads
      BUILD = /\Axixo-agent-(linux|darwin)-(amd64|arm64)\z/
      UNIT = Installer::UNIT_FILE

      Build = Data.define(:os, :arch, :file, :sha256)

      module_function

      def builds
        Dir.children(XixoAgent.binaries.to_s).sort.filter_map do |file|
          matched = file.match(BUILD)
          next unless matched

          path = binary(file)
          Build.new(os: matched[1], arch: matched[2], file: file, sha256: digest(path)) if path
        end
      rescue SystemCallError
        []
      end

      def binary(file)
        return nil unless file.to_s.match?(BUILD)

        path = XixoAgent.binaries + file.to_s
        path if File.lstat(path).file?
      rescue SystemCallError
        nil
      end

      def digest(path)
        stat = File.lstat(path)
        @digests ||= {}
        @digests[[ path.to_s, stat.size, stat.mtime.to_f ]] ||= Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
