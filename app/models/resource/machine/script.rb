class Resource
  class Machine
    class Script
      SYSTEMS = { "linux" => "Linux", "darwin" => "macOS" }.freeze

      def self.quoted(value)
        "'#{value.to_s.gsub("'", %q('\\\\''))}'"
      end

      UPDATER = "xixo-link-update".freeze
      LIB = "/usr/local/lib/xixo-link".freeze

      def initialize(xixo:, issuer:, builds: Downloads.builds, mac_reader: Downloads.mac_reader,
                     mac_reader_build: Downloads.mac_reader_build)
        @xixo = xixo
        @issuer = issuer
        @builds = builds.select { |build| SYSTEMS.key?(build.os) }
        @mac_reader = mac_reader
        @mac_reader_sum = mac_reader_build&.sha256
      end

      def to_s
        <<~SH
          #!/bin/sh
          set -eu

          xixo=#{q(@xixo)}
          issuer=#{q(@issuer)}
          reader=#{q(@mac_reader)}
          reader_sum=#{q(@mac_reader_sum)}

          say() { printf 'xixo link: %s\\n' "$*"; }
          fail() { printf 'xixo link: %s\\n' "$*" >&2; exit 1; }

          command -v curl > /dev/null 2>&1 || fail "this script needs curl."

          case "$(uname -s)" in
            Linux) os=linux ;;
            Darwin) os=darwin ;;
            *) fail "xixo link runs on Linux and macOS." ;;
          esac

          case "$(uname -m)" in
            x86_64 | amd64) arch=amd64 ;;
            aarch64 | arm64) arch=arm64 ;;
            *) fail "xixo link runs on x86_64 and ARM64 machines." ;;
          esac

          case "$os-$arch" in
          #{sums}
            *) fail "this xixo has no xixo link for $os on $arch." ;;
          esac

          work="$(mktemp -d)"
          trap 'rm -rf "$work"' EXIT
          trap 'exit 130' INT TERM

          checked() {
            if command -v sha256sum > /dev/null 2>&1; then
              printf '%s  %s\\n' "$1" "$2" | sha256sum -c - > /dev/null 2>&1
            else
              printf '%s  %s\\n' "$1" "$2" | shasum -a 256 -c - > /dev/null 2>&1
            fi
          }

          as_root() {
            if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
          }

          apt_get() {
            as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -qq "$@"
          }

          linux() {
            command -v systemctl > /dev/null 2>&1 || fail "xixo link runs as a systemd service, and this machine has no systemctl."
            [ "$(id -u)" -eq 0 ] || command -v sudo > /dev/null 2>&1 || fail "this script needs sudo, or run it as root."

            user="$(id -un)"
            group="$(id -gn)"
            if ! id -u #{UPDATER} > /dev/null 2>&1; then
              as_root useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin #{UPDATER}
            fi
            as_root install -d -m 0755 -o #{UPDATER} -g #{UPDATER} #{LIB}
            as_root install -m 0755 -o #{UPDATER} -g #{UPDATER} "$work/xixo-link" #{LIB}/xixo-link
            as_root rm -f #{LIB}/xixo-link.previous
            as_root ln -sfn #{LIB}/xixo-link /usr/local/bin/xixo-link

            if [ -r /etc/os-release ] && grep -Eqi '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
              say "Installing the programs that read files, with apt."
              if ! { apt_get update && apt_get install -y --no-install-recommends #{Downloads::PACKAGES.join(' ')} > /dev/null; }; then
                say "apt could not install every program, so other machines read the files this one cannot."
              fi
            else
              say "This system has no apt. Install poppler, tesseract, ffmpeg, vips, and LibreOffice to read more kinds of files here."
            fi

            as_root /usr/local/bin/xixo-link setup --xixo "$xixo" --issuer "$issuer" "$@"
            curl -fsSL -o "$work/xixo-link.service" "$xixo/link/download/xixo-link.service" || fail "the service did not download."
            /usr/local/bin/xixo-link unit --template "$work/xixo-link.service" --user "$user" > "$work/unit"
            as_root install -m 0644 "$work/unit" /etc/systemd/system/xixo-link.service
            for file in xixo-link-update.service xixo-link-update.path; do
              curl -fsSL -o "$work/$file" "$xixo/link/download/$file" || fail "the updater did not download."
              as_root install -m 0644 "$work/$file" "/etc/systemd/system/$file"
            done
            as_root install -d -m 0700 -o "$user" -g "$group" /var/lib/xixo-link

            /usr/local/bin/xixo-link up

            as_root systemctl daemon-reload
            as_root systemctl enable --quiet xixo-link
            as_root systemctl enable --now --quiet xixo-link-update.path
            as_root systemctl restart xixo-link
            say "xixo link is running."
          }

          mac() {
            dir="$HOME/Library/Application Support/xixo-link"
            agent="$HOME/Library/LaunchAgents/network.xixo.link.plist"
            mkdir -p "$dir/bin" "$HOME/Library/LaunchAgents"
            rm -rf "$dir/releases"
            install -m 0755 "$work/xixo-link" "$dir/bin/xixo-link"

            if [ -n "$reader_sum" ]; then
              if curl -fsSL -o "$work/xixo-mac-reader" "$xixo/link/download/xixo-mac-reader" &&
                checked "$reader_sum" "$work/xixo-mac-reader"; then
                install -m 0755 "$work/xixo-mac-reader" "$dir/bin/xixo-mac-reader"
              else
                say "The mac reader did not download, so this Mac reads files with the Homebrew programs it has."
              fi
            elif [ -n "$reader" ]; then
              if curl -fsL --proto =https -o "$work/xixo-mac-reader" "$reader" &&
                curl -fsL --proto =https -o "$work/xixo-mac-reader.sha256" "$reader.sha256" &&
                (cd "$work" && shasum -a 256 -c xixo-mac-reader.sha256 > /dev/null 2>&1); then
                install -m 0755 "$work/xixo-mac-reader" "$dir/bin/xixo-mac-reader"
              else
                say "No mac reader came with this release, so this Mac reads files with the Homebrew programs it has."
              fi
            fi

            "$dir/bin/xixo-link" setup --xixo "$xixo" --issuer "$issuer" "$@"
            curl -fsSL -o "$work/plist" "$xixo/link/download/xixo-link.plist" || fail "the launch agent did not download."
            sed "s|@HOME@|$HOME|g" "$work/plist" > "$work/agent"

            "$dir/bin/xixo-link" up

            service="gui/$(id -u)/network.xixo.link"
            launchctl bootout "$service" 2> /dev/null || true
            tries=0
            while launchctl print "$service" > /dev/null 2>&1 && [ "$tries" -lt 20 ]; do
              sleep 0.5
              tries=$((tries + 1))
            done
            install -m 0644 "$work/agent" "$agent"
            tries=0
            until launchctl bootstrap "gui/$(id -u)" "$agent" 2> /dev/null; do
              tries=$((tries + 1))
              [ "$tries" -lt 10 ] || fail "macOS did not load the xixo link service. Run the command again."
              sleep 1
            done
            launchctl kickstart "$service"
            say "xixo link is running."

            if grep -Eq "$HOME/(Desktop|Documents|Downloads|Library/Mobile Documents)" "$dir/config.json" 2> /dev/null; then
              say "macOS asks before xixo link reads Desktop, Documents, or Downloads."
              say "Drag xixo-link from the Finder window into Full Disk Access, and turn it on. xixo link starts reading by itself."
              open -R "$dir/bin/xixo-link" 2> /dev/null || true
              open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2> /dev/null || true
            fi
          }

          say "Downloading xixo link for $os on $arch."
          curl -fsSL -o "$work/xixo-link" "$xixo/link/download/xixo-link-$os-$arch" || fail "the download failed."
          checked "$sum" "$work/xixo-link" || fail "the download did not match its checksum, so nothing was installed."
          chmod 0755 "$work/xixo-link"

          case "$os" in
            linux) linux "$@" ;;
            darwin) mac "$@" ;;
          esac
        SH
      end

      private

        def q(value)
          self.class.quoted(value)
        end

        def sums
          @builds.map { |build| "  #{build.os}-#{build.arch}) sum=#{build.sha256} ;;" }.join("\n")
        end
    end
  end
end
