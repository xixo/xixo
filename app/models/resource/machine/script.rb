class Resource
  class Machine
    class Script
      SYSTEMS = { "linux" => "Linux", "darwin" => "macOS" }.freeze

      def self.quoted(value)
        "'#{value.to_s.gsub("'", %q('\\\\''))}'"
      end

      LIB = "/usr/local/lib/xixo-link".freeze

      def initialize(xixo:, issuer:, builds: Downloads.builds)
        @xixo = xixo
        @issuer = issuer
        @builds = builds.select { |build| SYSTEMS.key?(build.os) }
      end

      def to_s
        <<~SH
          #!/bin/sh
          set -eu

          xixo=#{q(@xixo)}
          issuer=#{q(@issuer)}

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
              printf 'The link-up command stopped before it finished.\\n' >&2
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

            if [ "$(id -u)" -eq 0 ] || sudo -n true 2> /dev/null; then
              step "Installing xixo link in #{LIB}, /etc/xixo-link, and /etc/systemd/system, and the programs that read files."
            else
              step "Installing xixo link and the programs that read files. sudo asks for your password to write to #{LIB}, /etc/xixo-link, and /etc/systemd/system."
              sudo -v || fail "sudo did not get your password, so nothing was installed. Run the command again in a terminal, or run it as root."
            fi

            as_root "$work/xixo-link" install --xixo "$xixo" --issuer "$issuer" --user "$user" --from "$work/xixo-link" "$@" ||
              fail "xixo link did not install. Read what it said above, then run the command again."

            if [ -n "$linked" ]; then
              step "Checking the link with xixo."
            else
              step "Asking xixo to approve this machine."
            fi
            "$work/xixo-link" up

            if as_root systemctl is-enabled --quiet xixo-link 2> /dev/null; then
              step "Restarting xixo link with the new version. This can take up to 15 seconds."
            else
              step "Starting xixo link."
            fi
            as_root "$work/xixo-link" start ||
              fail "systemd did not start xixo link. See why with: journalctl -u xixo-link -n 50"
            sleep 2
            as_root systemctl is-active --quiet xixo-link ||
              fail "xixo link stopped right after it started. See why with: journalctl -u xixo-link -n 50"

            done_line /var/lib/xixo-link/registration.json
            "$work/xixo-link" status || true
          }

          mac() {
            dir="$HOME/Library/Application Support/xixo-link"
            shown="$(printf '%s%s' '~' "${dir#"$HOME"}")"
            service="gui/$(id -u)/network.xixo.link"
            replaced=''
            [ ! -e "$dir/bin/xixo-link" ] || replaced=1

            supervises=''
            if [ -x "$dir/bin/xixo-link" ] && "$dir/bin/xixo-link" run -h 2>&1 | grep -q -- '-supervised'; then
              supervises=1
            fi

            if [ -n "$supervises" ]; then
              step "Installing xixo link $version in $shown as an update."
            else
              step "Installing xixo link in $shown."
            fi
            "$work/xixo-link" install --xixo "$xixo" --issuer "$issuer" --from "$work/xixo-link" "$@" ||
              fail "xixo link did not install. Read what it said above, then run the command again."

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
            "$work/xixo-link" start ||
              fail "macOS did not load the xixo link service. Run the command again."

            done_line "$dir/state/registration.json"
            "$work/xixo-link" status || true

            if grep -Eq "$HOME/(Desktop|Documents|Downloads|Library/Mobile Documents)|\\"/Volumes/" "$dir/config.json" 2> /dev/null; then
              say ""
              if [ -n "$supervises" ]; then
                say "Full Disk Access stays as it was, since this update leaves $shown/bin/xixo-link in place."
              else
                say "${bold}One more step:${plain} macOS asks for your permission before xixo link reads Desktop, Documents, Downloads, iCloud Drive, or another disk."
                say "  1. In System Settings, open Privacy & Security, then Full Disk Access. This script opened it for you."
                [ -z "$replaced" ] || say "     Select any xixo-link already in the list, and remove it with the minus button."
                say "  2. Drag xixo-link from the Finder window into the list. Or click the plus button, press Command-Shift-G, and enter:"
                say "     $shown/bin/xixo-link"
                say "  3. Turn on the switch beside xixo-link. xixo link starts reading those folders within a minute."
                open -R "$dir/bin/xixo-link" 2> /dev/null || true
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2> /dev/null || true
              fi
            fi
          }

          case "$os" in
            linux) state=/var/lib/xixo-link total=4 ;;
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
