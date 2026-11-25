#!/bin/sh
# Install the MoonBit toolchain pinned in .moonbit-version, or an explicit
# version (pass "latest" for the newest release).
# Usage: scripts/install_moonbit.sh [version]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/.moonbit-version"

version="${1:-}"
if [ -z "$version" ]; then
  version="$(sed -n 's/^moon=//p' "$VERSION_FILE" | head -n 1)"
fi

if [ -z "$version" ]; then
  echo "error: no MoonBit version given and none found in $VERSION_FILE" >&2
  exit 1
fi

echo "Installing MoonBit $version"
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- "$version"
