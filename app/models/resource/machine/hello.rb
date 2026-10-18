class Resource
  class Machine
    module Hello
      UPDATES = %w[systemd self].freeze
      SHA256 = /\A[0-9a-f]{64}\z/

      module_function

      def from(said)
        said = said.to_h
        described = Description.from(said["details"], folders(said["folders"]))

        {
          "version" => text(said["version"]),
          "os" => text(said["os"]),
          "arch" => text(said["arch"]),
          "hostname" => text(said["hostname"]),
          "folders" => folders(said["folders"]),
          "writable" => folders(said["writable"]) & folders(said["folders"]),
          "details" => described,
          "services" => described["services"],
          "extractors" => described["readers"],
          "warnings" => warnings(said["warnings"]),
          "sha256" => digest(said["sha256"]),
          "mac_reader" => digest(said["mac_reader"]),
          "updates" => (said["updates"] if UPDATES.include?(said["updates"])),
          "lend" => said["lend"] == true
        }
      end

      def digest(value)
        value if value.is_a?(String) && value.match?(SHA256)
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
        listed(value).select { |name| name.is_a?(String) && EXTRACTORS.include?(name) }.uniq.sort
      end

      def warnings(value)
        listed(value).first(MOST_WARNINGS * 4).filter_map do |said|
          next unless said.is_a?(String)

          said.scrub.gsub(/[[:cntrl:]]/, " ").squish.first(MOST_WARNING).presence
        end.uniq.first(MOST_WARNINGS)
      end

      def listed(value)
        value.is_a?(Array) ? value : []
      end

      def services(value)
        Array(value).first(MOST_SERVICES).filter_map do |service|
          next unless service.is_a?(Hash) && SERVICE_KINDS.include?(service["kind"])

          port = service["port"]
          next unless port.is_a?(Integer) && port.between?(1, 65_535)

          { "kind" => service["kind"], "port" => port }
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
