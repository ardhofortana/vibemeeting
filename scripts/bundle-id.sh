#!/bin/bash
# Prints the app's bundle ID from project.yml, so scripts and docs never
# hardcode it. Usage:
#   scripts/bundle-id.sh           # release build
#   scripts/bundle-id.sh debug     # development build (what Xcode's Run makes)
# For example: tccutil reset AudioCapture "$(scripts/bundle-id.sh debug)"
set -euo pipefail
cd "$(dirname "$0")/.."

ids=$(sed -nE 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *([^ #]+).*/\1/p' project.yml)
release=$(grep -v '\.debug$' <<<"$ids" | head -n 1 || true)
if [ -z "$release" ]; then
  echo "No PRODUCT_BUNDLE_IDENTIFIER in project.yml." >&2
  exit 1
fi

case "${1:-release}" in
  release)
    echo "$release"
    ;;
  debug)
    if ! grep -qxF "$release.debug" <<<"$ids"; then
      echo "project.yml has no development bundle ID ($release.debug)." >&2
      exit 1
    fi
    echo "$release.debug"
    ;;
  *)
    echo "Usage: scripts/bundle-id.sh [release|debug]" >&2
    exit 1
    ;;
esac
