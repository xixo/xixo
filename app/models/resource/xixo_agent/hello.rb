class Resource
  class XixoAgent
    module Hello
      module_function

      def from(said)
        said = said.to_h

        {
          "version" => text(said["version"]),
          "os" => text(said["os"]),
          "arch" => text(said["arch"]),
          "hostname" => text(said["hostname"]),
          "folders" => folders(said["folders"]),
          "writable" => folders(said["writable"]) & folders(said["folders"]),
          "services" => services(said["services"]),
          "extractors" => extractors(said["extractors"])
        }
      end

      def text(value)
        value.is_a?(String) ? value.scrub.gsub(/[[:cntrl:]]/, "").strip.first(MOST_TEXT).presence : nil
      end

      def folders(value)
        Array(value).first(MOST_FOLDERS).filter_map { |path| folder(path) }.uniq.sort
      end

      def folder(path)
        return unless path.is_a?(String) && path.bytesize <= MOST_PATH && path.valid_encoding?
        return unless path.start_with?("/") && !path.include?("\0")

        path if Pathname.new(path).cleanpath.to_s == path
      end

      def extractors(value)
        Array(value).select { |name| name.is_a?(String) && EXTRACTORS.include?(name) }.uniq.sort
      end

      def services(value)
        Array(value).first(MOST_SERVICES).filter_map do |service|
          next unless service.is_a?(Hash) && SERVICE_KINDS.include?(service["kind"])

          port = service["port"]
          next unless port.is_a?(Integer) && port.between?(1, 65_535)

          { "kind" => service["kind"], "port" => port, "address" => address(service["address"]) }
        end
      end

      def address(value)
        IPAddr.new(value.to_s).to_s if value.present?
      rescue IPAddr::Error
        nil
      end
    end
  end
end
