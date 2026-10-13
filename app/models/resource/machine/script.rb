class Resource
  class Machine
    class Script
      SYSTEMS = { "linux" => "Linux", "darwin" => "macOS" }.freeze

      def self.quoted(value)
        "'#{value.to_s.gsub("'", %q('\\\\''))}'"
      end

      UPDATER = "xixo-link-update".freeze
      LIB = "/usr/local/lib/xixo-link".freeze
      READS = "PDFs, images, audio, video, and office documents".freeze

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

          bold=''
          green=''
          plain=''
          alarm=''
          calm=''
          if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
            if [ -t 1 ]; then
              bold="$(printf '\\033[1m')"
              green="$(printf '\\033[32m')"
              plain="$(printf '\\033[0m')"
            fi
            if [ -t 2 ]; then
              alarm="$(printf '\\033[1;31m')"
              calm="$(printf '\\033[0m')"
            fi
          fi

          steps=0
          told=''
          work=''

          say() { printf '%s\\n' "$*"; }
          step() {
            steps=$((steps + 1))
            printf '%s%s.%s %s\\n' "$bold" "$steps" "$plain" "$*"
          }
          note() { printf '   %s\\n' "$*"; }
          fail() {
            printf '%sError:%s %s\\n' "$alarm" "$calm" "$*" >&2
            told=1
            exit 1
          }

          finish() {
            status=$?
            [ -z "$work" ] || rm -rf "$work"
            if [ "$status" -eq 130 ]; then
              printf '\\nStopped. Run the command again to finish linking up this machine.\\n' >&2
            elif [ "$status" -ne 0 ] && [ -z "$told" ]; then
              printf 'xixo link did not finish linking up this machine. The message above says what went wrong.\\n' >&2
            fi
          }
          trap finish EXIT
          trap 'exit 130' INT TERM

          command -v curl > /dev/null 2>&1 || fail "this script needs curl. Install curl, then run the command again."

          case "$(uname -s)" in
            Linux) os=linux system=Linux ;;
            Darwin) os=darwin system=macOS ;;
            *) fail "xixo link runs on Linux and macOS, and this machine runs $(uname -s)." ;;
          esac

          case "$(uname -m)" in
            x86_64 | amd64) arch=amd64 ;;
            aarch64 | arm64) arch=arm64 ;;
            *) fail "xixo link runs on x86_64 and ARM64 processors, and this machine has $(uname -m)." ;;
          esac

          case "$os-$arch" in
          #{sums}
            *) fail "this xixo has no xixo link for $system on $arch. Ask the administrator of xixo to add that build." ;;
          esac

          work="$(mktemp -d)"

          checked() {
            if command -v sha256sum > /dev/null 2>&1; then
              printf '%s  %s\\n' "$1" "$2" | sha256sum -c - > /dev/null 2>&1
            else
              printf '%s  %s\\n' "$1" "$2" | shasum -a 256 -c - > /dev/null 2>&1
            fi
          }

          fetch() {
            curl -fsSL -o "$2" "$xixo/link/download/$1" ||
              fail "$1 did not download from $xixo. Check that this machine can reach xixo, then run the command again."
          }

          as_root() {
            if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
          }

          apt_get() {
            as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -q "$@"
          }

          installed() {
            for package in "$@"; do
              dpkg-query -W -f='${Status}' "$package" 2> /dev/null | grep -q 'ok installed' || return 1
            done
          }

          kept() {
            [ -s "$1" ] && cmp -s "$1" "$work/registration.json"
          }

          done_line() {
            say ""
            if [ -n "$linked" ] && kept "$1"; then
              say "${green}Done.${plain} xixo link is updated and running, and this machine kept its approval."
            else
              say "${green}Done.${plain} This machine is linked up, and xixo link is running."
            fi
            say ""
          }

          linux() {
            command -v systemctl > /dev/null 2>&1 || fail "xixo link runs as a systemd service, and this machine has no systemctl."
            [ "$(id -u)" -eq 0 ] || command -v sudo > /dev/null 2>&1 || fail "this script needs sudo to install xixo link. Install sudo, or run the command as root."

            user="$(id -un)"
            group="$(id -gn)"

            if [ "$(id -u)" -eq 0 ] || sudo -n true 2> /dev/null; then
              step "Installing xixo link in #{LIB}, /etc/xixo-link, and /etc/systemd/system."
            else
              step "Installing xixo link. sudo asks for your password to write to #{LIB}, /etc/xixo-link, and /etc/systemd/system."
              sudo -v || fail "sudo did not accept a password, so nothing was installed. Run the command again, or run it as root."
            fi

            if ! id -u #{UPDATER} > /dev/null 2>&1; then
              as_root useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin #{UPDATER}
            fi
            as_root install -d -m 0755 -o #{UPDATER} -g #{UPDATER} #{LIB}
            as_root install -m 0755 -o #{UPDATER} -g #{UPDATER} "$work/xixo-link" #{LIB}/xixo-link
            as_root rm -f #{LIB}/xixo-link.previous
            as_root ln -sfn #{LIB}/xixo-link /usr/local/bin/xixo-link

            as_root "$work/xixo-link" setup --xixo "$xixo" --issuer "$issuer" "$@"
            fetch xixo-link.service "$work/xixo-link.service"
            "$work/xixo-link" unit --template "$work/xixo-link.service" --user "$user" > "$work/unit"
            as_root install -m 0644 "$work/unit" /etc/systemd/system/xixo-link.service
            for file in xixo-link-update.service xixo-link-update.path; do
              fetch "$file" "$work/$file"
              as_root install -m 0644 "$work/$file" "/etc/systemd/system/$file"
            done
            as_root install -d -m 0700 -o "$user" -g "$group" /var/lib/xixo-link

            if [ -r /etc/os-release ] && grep -Eqi '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
              if installed #{Downloads::PACKAGES.join(' ')}; then
                step "Checking the programs that read #{READS}. They are installed already."
              else
                step "Installing the programs that read #{READS}, with apt. This can take a few minutes."
                log="$(mktemp "${TMPDIR:-/tmp}/xixo-link-apt.XXXXXX")"
                if apt_get update > "$log" 2>&1 && apt_get install -y --no-install-recommends #{Downloads::PACKAGES.join(' ')} >> "$log" 2>&1; then
                  rm -f "$log"
                else
                  note "apt did not install every program. This machine reads the files it can, and other machines read the rest."
                  note "The last lines apt wrote:"
                  tail -n 5 "$log" | sed 's/^/     /'
                  note "The whole log is in $log."
                fi
              fi
            else
              step "Skipping the programs that read #{READS}, since this system has no apt."
              note "To read more kinds of files here, install poppler, tesseract, ffmpeg, vips, and LibreOffice."
            fi

            if [ -n "$linked" ]; then
              step "Checking the link with xixo."
            else
              step "Asking xixo to approve this machine."
            fi
            "$work/xixo-link" up

            if systemctl is-active --quiet xixo-link; then
              step "Restarting xixo link with the new version. This can take up to a minute."
            else
              step "Starting xixo link."
            fi
            as_root systemctl daemon-reload
            as_root systemctl enable --quiet xixo-link
            as_root systemctl enable --now --quiet xixo-link-update.path
            as_root systemctl restart xixo-link ||
              fail "systemd did not start xixo link. See why with: journalctl -u xixo-link -n 50"
            sleep 2
            systemctl is-active --quiet xixo-link ||
              fail "xixo link stopped right after it started. See why with: journalctl -u xixo-link -n 50"

            done_line /var/lib/xixo-link/registration.json
            "$work/xixo-link" status || true
          }

          mac() {
            dir="$HOME/Library/Application Support/xixo-link"
            agent="$HOME/Library/LaunchAgents/network.xixo.link.plist"
            service="gui/$(id -u)/network.xixo.link"
            replaced=''
            [ ! -e "$dir/bin/xixo-link" ] || replaced=1

            supervises=''
            if [ -x "$dir/bin/xixo-link" ] && "$dir/bin/xixo-link" run -h 2>&1 | grep -q -- '-supervised'; then
              supervises=1
            fi

            if [ -n "$supervises" ]; then
              step "Installing xixo link $version in $dir as an update. Full Disk Access stays as it is."
            else
              step "Installing xixo link in $dir."
            fi
            mkdir -p "$dir/bin" "$HOME/Library/LaunchAgents"

            if [ -n "$reader_sum" ]; then
              if curl -fsSL -o "$work/xixo-mac-reader" "$xixo/link/download/xixo-mac-reader" &&
                checked "$reader_sum" "$work/xixo-mac-reader"; then
                chmod 0755 "$work/xixo-mac-reader"
              else
                rm -f "$work/xixo-mac-reader"
                note "The mac reader did not download, so this Mac reads files with the Homebrew programs it has."
              fi
            elif [ -n "$reader" ]; then
              if curl -fsL --proto =https -o "$work/xixo-mac-reader" "$reader" &&
                curl -fsL --proto =https -o "$work/xixo-mac-reader.sha256" "$reader.sha256" &&
                (cd "$work" && shasum -a 256 -c xixo-mac-reader.sha256 > /dev/null 2>&1); then
                chmod 0755 "$work/xixo-mac-reader"
              else
                rm -f "$work/xixo-mac-reader"
                note "No mac reader came with this release, so this Mac reads files with the Homebrew programs it has."
              fi
            fi

            if [ -n "$supervises" ]; then
              if [ ! -f "$work/xixo-mac-reader" ] && [ -f "$dir/bin/xixo-mac-reader" ]; then
                cp "$dir/bin/xixo-mac-reader" "$work/xixo-mac-reader"
              fi
              "$work/xixo-link" stage --releases "$dir/releases"
            else
              rm -rf "$dir/releases"
              install -m 0755 "$work/xixo-link" "$dir/bin/xixo-link"
              [ ! -f "$work/xixo-mac-reader" ] || install -m 0755 "$work/xixo-mac-reader" "$dir/bin/xixo-mac-reader"
            fi

            "$work/xixo-link" setup --xixo "$xixo" --issuer "$issuer" "$@"
            curl -fsSL -o "$work/plist" "$xixo/link/download/xixo-link.plist" ||
              fail "the launch agent did not download from $xixo. Check that this machine can reach xixo, then run the command again."
            sed "s|@HOME@|$HOME|g" "$work/plist" > "$work/agent"

            if [ -n "$linked" ]; then
              step "Checking the link with xixo."
            else
              step "Asking xixo to approve this machine."
            fi
            "$work/xixo-link" up

            if launchctl print "$service" > /dev/null 2>&1; then
              step "Restarting xixo link with the new version."
            else
              step "Starting xixo link."
            fi
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

            done_line "$dir/state/registration.json"
            "$work/xixo-link" status || true

            if grep -Eq "$HOME/(Desktop|Documents|Downloads|Library/Mobile Documents)|\\"/Volumes/" "$dir/config.json" 2> /dev/null; then
              say ""
              if [ -n "$supervises" ]; then
                say "Full Disk Access stays as it was, since this update leaves $dir/bin/xixo-link in place."
              else
                say "${bold}One more step:${plain} macOS asks for your permission before xixo link reads Desktop, Documents, Downloads, iCloud Drive, or another disk."
                say "  1. In System Settings, open Privacy & Security, then Full Disk Access. This script opened it for you."
                [ -z "$replaced" ] || say "     Select any xixo-link already in the list, and remove it with the minus button."
                say "  2. Drag xixo-link from the Finder window into the list. Or click the plus button, press Command-Shift-G, and enter:"
                say "     $dir/bin/xixo-link"
                say "  3. Turn on the switch beside xixo-link. xixo link starts reading those folders within a minute."
                open -R "$dir/bin/xixo-link" 2> /dev/null || true
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2> /dev/null || true
              fi
            fi
          }

          case "$os" in
            linux) state=/var/lib/xixo-link total=5 ;;
            darwin) state="$HOME/Library/Application Support/xixo-link/state" total=4 ;;
          esac

          linked=''
          if [ -s "$state/registration.json" ] && cp "$state/registration.json" "$work/registration.json" 2> /dev/null; then
            linked=1
            say "Updating xixo link on this machine, which is linked up with $xixo. This takes $total steps."
          else
            say "Linking up this machine with $xixo. This takes $total steps."
          fi
          say ""

          step "Downloading xixo link for $system on $arch."
          fetch "xixo-link-$os-$arch" "$work/xixo-link"
          checked "$sum" "$work/xixo-link" || fail "the download did not match its checksum, so nothing was installed. Run the command again. If it fails again, tell the administrator of xixo."
          chmod 0755 "$work/xixo-link"
          version="$("$work/xixo-link" version)"
          [ "$#" -eq 0 ] || "$work/xixo-link" setup --config "$work/folders.json" --xixo "$xixo" --issuer "$issuer" "$@"

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
