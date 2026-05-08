#!/usr/bin/env bash
# Configure /etc/nix/nix.conf and /etc/ssh/ssh_config.d so the system
# nix-daemon can offload x86_64-linux / aarch64-linux builds to a
# `darwin.linux-builder` VM running on localhost:31022.
#
# Usage (after generating a keypair, see README):
#   sudo KEYS=~/.linux-builder/keys USER_NAME=$USER \
#     bash scripts/setup-linux-builder.sh
#
# Both env vars have sensible defaults pulled from $SUDO_USER if missing.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script configures a macOS host to use darwin.linux-builder; run it on macOS." >&2
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

USER_NAME="${USER_NAME:-${SUDO_USER:-}}"
if [ -z "$USER_NAME" ]; then
  echo "Set USER_NAME=<your-username> (no \$SUDO_USER in env)" >&2
  exit 1
fi
# Validate USER_NAME against a conservative POSIX-style username regex before
# we splice it into grep patterns and `sed` replacements (and the dscl path)
# below. This forecloses on regex / sed-replacement metacharacters (`&`, `\`,
# `/`, `[`, etc.) corrupting `/etc/nix/nix.conf` or causing a mis-detect of
# existing membership. macOS `useradd`/`sysadminctl` enforce similar rules.
if ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "USER_NAME '$USER_NAME' is not a valid POSIX username (expected [a-z_][a-z0-9_-]*)" >&2
  exit 1
fi
# Look up home dir via dscl rather than `eval echo "~$USER_NAME"` so a hostile
# USER_NAME (containing backticks, $(...) etc) can't get executed as root.
# `dscl . -read` prints `NFSHomeDirectory: /Users/foo`; strip the leading
# `NFSHomeDirectory:` label and surrounding whitespace rather than
# `awk '{print $2}'` so paths with spaces survive intact.
#
# We capture dscl's exit status explicitly. Under `set -euo pipefail`, a
# `dscl ... | sed ...` pipe whose dscl half fails (e.g. unknown user) would
# exit the script before our friendly error check runs.
if ! DSCL_OUT=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null); then
  echo "Could not resolve home directory for user '$USER_NAME' via dscl (user may not exist)" >&2
  exit 1
fi
USER_HOME=$(printf '%s\n' "$DSCL_OUT" | sed -E 's/^NFSHomeDirectory:[[:space:]]*//')
# Trim any leading/trailing whitespace just in case.
USER_HOME="${USER_HOME#"${USER_HOME%%[![:space:]]*}"}"
USER_HOME="${USER_HOME%"${USER_HOME##*[![:space:]]}"}"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "Could not resolve home directory for user '$USER_NAME' via dscl" >&2
  exit 1
fi
KEYS="${KEYS:-$USER_HOME/.linux-builder/keys}"

if [ ! -f "$KEYS/builder_ed25519" ] || [ ! -f "$KEYS/builder_ed25519.pub" ]; then
  echo "Missing keypair at $KEYS/builder_ed25519{,.pub}" >&2
  echo "Generate it first:" >&2
  echo "  mkdir -p $KEYS" >&2
  echo "  ssh-keygen -q -f $KEYS/builder_ed25519 -t ed25519 -N '' -C 'builder@localhost'" >&2
  exit 1
fi

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  arm64|aarch64) BUILDER_SYS=aarch64-linux ;;
  x86_64)        BUILDER_SYS=x86_64-linux ;;
  *) echo "unknown arch: $HOST_ARCH" >&2; exit 1 ;;
esac

echo "==> installing builder keys to /etc/nix/"
mkdir -p /etc/nix
install -m 0600 -o root -g wheel "$KEYS/builder_ed25519"     /etc/nix/builder_ed25519
install -m 0644 -o root -g wheel "$KEYS/builder_ed25519.pub" /etc/nix/builder_ed25519.pub

echo "==> writing /etc/ssh/ssh_config.d/100-linux-builder.conf"
mkdir -p /etc/ssh/ssh_config.d
cat > /etc/ssh/ssh_config.d/100-linux-builder.conf <<'EOF'
Host linux-builder
  Hostname localhost
  HostKeyAlias linux-builder
  Port 31022
  User builder
  IdentityFile /etc/nix/builder_ed25519
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /etc/nix/builder_known_hosts
EOF
chmod 0644 /etc/ssh/ssh_config.d/100-linux-builder.conf

# Match an Include directive that points at our snippet dir even if the
# author wrote it with multiple spaces, tabs, or surrounding whitespace.
# Lines starting with `#` are skipped so commented-out examples don't count.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*[[:space:]]*$' \
     /etc/ssh/ssh_config 2>/dev/null; then
  echo "==> adding 'Include /etc/ssh/ssh_config.d/*' to /etc/ssh/ssh_config"
  printf '\nInclude /etc/ssh/ssh_config.d/*\n' >> /etc/ssh/ssh_config
fi

echo "==> updating /etc/nix/nix.conf"
NC=/etc/nix/nix.conf
touch "$NC"

# Take a single timestamped backup before any in-place edits so repeat runs
# don't clobber a useful prior backup (sed -i.bak overwrites .bak each time).
NC_BAK="${NC}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$NC" "$NC_BAK"
echo "    (backed up $NC -> $NC_BAK)"

# Anchor on `^[[:space:]]*trusted-users[[:space:]]*=` so we don't accidentally
# match `extra-trusted-users` and append to the wrong key. The leading
# `[[:space:]]*` lets us also detect indented entries — Nix tolerates
# leading whitespace before keys, and a column-0-only check would
# mis-detect existing `trusted-users` and append a duplicate line.
#
# Membership check uses a whitespace-or-line-edge boundary instead of
# `grep -w`. `-w` defines word characters as `[A-Za-z0-9_]`, which excludes
# `-`, so a username like `john-doe` is mis-detected as not-present and
# would be appended on every run.
if grep -qE '^[[:space:]]*trusted-users[[:space:]]*=' "$NC"; then
  if ! grep -E '^[[:space:]]*trusted-users[[:space:]]*=' "$NC" \
     | grep -qE "(^|[[:space:]])$USER_NAME([[:space:]]|$)"; then
    # BSD sed (macOS) requires an explicit '' extension after -i; using a
    # non-empty extension would clobber the timestamped backup we took above.
    # Preserve any existing leading whitespace via the captured group.
    sed -i '' -E "s/^([[:space:]]*trusted-users[[:space:]]*=.*)$/\\1 $USER_NAME/" "$NC"
  fi
else
  echo "trusted-users = root $USER_NAME" >> "$NC"
fi

# Builder spec columns:
#   url system sshKey maxJobs speedFactor supportedFeatures mandatoryFeatures publicHostKey
#
# We want to register the linux-builder entry. If the user already has *other*
# builders configured (e.g. a remote x86_64-linux box, or linux-builder PLUS
# something else on the same line separated by `;`, or multiple `builders =`
# lines), wholesale-deleting the existing entries would silently drop them.
# Skip the warning only when there is *exactly one* `builders =` line, with
# no `;`, whose value starts with our linux-builder marker.
if grep -qE '^[[:space:]]*builders[[:space:]]*=' "$NC"; then
  EXISTING_BUILDERS=$(grep -E '^[[:space:]]*builders[[:space:]]*=' "$NC" || true)
  # `grep -c` counts matches; tolerate the no-match case (which `set -e`
  # would otherwise treat as fatal even though we already gated on `-q`).
  BUILDER_LINE_COUNT=$(grep -cE '^[[:space:]]*builders[[:space:]]*=' "$NC" || true)
  EXISTING_VALUE=$(printf '%s\n' "$EXISTING_BUILDERS" | sed -E 's/^[[:space:]]*builders[[:space:]]*=[[:space:]]*//')
  if [ "${BUILDER_LINE_COUNT:-0}" -ne 1 ] \
     || printf '%s\n' "$EXISTING_VALUE" | grep -q ';' \
     || ! printf '%s\n' "$EXISTING_VALUE" | grep -qE '^ssh-ng://builder@linux-builder[[:space:]]'; then
    echo "" >&2
    echo "WARNING: $NC already has a builders entry:" >&2
    echo "  $EXISTING_BUILDERS" >&2
    echo "This script will replace it with a single linux-builder entry." >&2
    echo "Existing builders will be lost. A backup is at $NC_BAK." >&2
    echo "If you need to keep them, hit Ctrl-C now and merge manually." >&2
    echo "" >&2
    sleep 5
  fi
fi
sed -i '' -E '/^[[:space:]]*builders[[:space:]]*=/d; /^[[:space:]]*builders-use-substitutes[[:space:]]*=/d' "$NC"
# supportedFeatures intentionally omits `kvm`: darwin.linux-builder is a
# QEMU VM accelerated via HVF on macOS, so /dev/kvm is NOT exposed to the
# Linux guest. Advertising `kvm` would cause Nix to schedule kvm-required
# builds (e.g. NixOS VM tests) onto this builder and then fail at build
# time. Users with a real KVM-capable Linux remote should add it as a
# separate builders entry.
cat >> "$NC" <<EOF
builders = ssh-ng://builder@linux-builder ${BUILDER_SYS} /etc/nix/builder_ed25519 4 - benchmark,big-parallel - -
builders-use-substitutes = true
EOF

echo "==> reloading nix-daemon"
launchctl kickstart -k system/org.nixos.nix-daemon

echo "Done. Builder config installed for $USER_NAME (system: $BUILDER_SYS)."
