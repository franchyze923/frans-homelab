#!/usr/bin/env bash
# Update k9s on this host from the project's own GitHub release RPM.
#
# k9s here is installed from a downloaded RPM (dnf shows it as
# "@@commandline"), so no repo ever pulls updates for it. This script does
# the manual dance in one go: look up the latest release, skip if already
# current, download the RPM + checksums.sha256, verify the checksum, then
# `dnf install` the local file so the rpm database stays accurate.
# Going via dnf (not `rpm -i`) is deliberate -- same reason as always: keep
# `dnf list installed` honest.
#
# Usage: ./update-k9s.sh            # upgrade to latest if newer
#        ./update-k9s.sh --check    # just report installed vs latest
#        ./update-k9s.sh v0.51.0    # pin a specific release tag
#        ./update-k9s.sh --force    # reinstall even if versions match
set -euo pipefail

REPO="derailed/k9s"
CHECK=0; FORCE=0; WANT=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    v[0-9]*) WANT="$a" ;;
    *) echo "usage: $0 [--check] [--force] [vX.Y.Z]" >&2; exit 2 ;;
  esac
done

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
command -v dnf >/dev/null || { echo "dnf not found -- this script is for RPM hosts" >&2; exit 1; }

installed="$(k9s version --short 2>/dev/null | awk '/^Version/ {print $2}')"
installed="${installed:-none}"

if [ -n "$WANT" ]; then
  latest="$WANT"
else
  latest="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  [ -n "$latest" ] || { echo "could not determine latest release from GitHub" >&2; exit 1; }
fi

echo "installed: $installed"
echo "target:    $latest"
[ "$CHECK" -eq 1 ] && exit 0

if [ "$installed" = "$latest" ] && [ "$FORCE" -eq 0 ]; then
  echo "already current -- nothing to do (use --force to reinstall)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$REPO/releases/download/$latest"
rpm="k9s_linux_${ARCH}.rpm"

echo "downloading $rpm ..."
curl -fsSL -o "$tmp/$rpm"              "$base/$rpm"
curl -fsSL -o "$tmp/checksums.sha256"  "$base/checksums.sha256"

echo "verifying checksum ..."
( cd "$tmp" && grep " $rpm\$" checksums.sha256 | sha256sum -c - )

echo "installing via dnf (sudo) ..."
sudo dnf -y install "$tmp/$rpm"

echo
k9s version --short
