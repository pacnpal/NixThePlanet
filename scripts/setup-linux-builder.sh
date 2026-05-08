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

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

USER_NAME="${USER_NAME:-${SUDO_USER:-}}"
if [ -z "$USER_NAME" ]; then
  echo "Set USER_NAME=<your-username> (no \$SUDO_USER in env)" >&2
  exit 1
fi
USER_HOME=$(eval echo "~$USER_NAME")
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

if ! grep -q '^Include /etc/ssh/ssh_config.d/\*' /etc/ssh/ssh_config 2>/dev/null; then
  echo "==> adding 'Include /etc/ssh/ssh_config.d/*' to /etc/ssh/ssh_config"
  printf '\nInclude /etc/ssh/ssh_config.d/*\n' >> /etc/ssh/ssh_config
fi

echo "==> updating /etc/nix/nix.conf"
NC=/etc/nix/nix.conf
touch "$NC"

if grep -qE '^trusted-users' "$NC"; then
  if ! grep -E '^trusted-users' "$NC" | grep -qw "$USER_NAME"; then
    sed -i.bak -E "s/^trusted-users(.*)$/trusted-users\\1 $USER_NAME/" "$NC"
  fi
else
  echo "trusted-users = root $USER_NAME" >> "$NC"
fi

# Builder spec columns:
#   url system sshKey maxJobs speedFactor supportedFeatures mandatoryFeatures publicHostKey
sed -i.bak -E '/^builders[[:space:]]*=/d; /^builders-use-substitutes[[:space:]]*=/d' "$NC"
cat >> "$NC" <<EOF
builders = ssh-ng://builder@linux-builder ${BUILDER_SYS} /etc/nix/builder_ed25519 4 - benchmark,big-parallel,kvm - -
builders-use-substitutes = true
EOF

echo "==> reloading nix-daemon"
launchctl kickstart -k system/org.nixos.nix-daemon

echo "Done. Builder config installed for $USER_NAME (system: $BUILDER_SYS)."
