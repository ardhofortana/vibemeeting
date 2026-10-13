#!/bin/bash
# Saves your Apple Developer Team ID to Configs/Local.xcconfig so it survives
# `xcodegen generate`. Usage:
#   scripts/save-signing-team.sh            # reads the Team you picked in Xcode
#   scripts/save-signing-team.sh ABCDE12345 # or pass it directly
set -euo pipefail
cd "$(dirname "$0")/.."

team="${1:-}"
if [ -z "$team" ] && [ -f VibeMeeting.xcodeproj/project.pbxproj ]; then
  team=$(grep -E 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' VibeMeeting.xcodeproj/project.pbxproj | head -n 1 | sed -E 's/.*= ([A-Z0-9]{10});.*/\1/' || true)
fi
if [ -z "$team" ]; then
  echo "No Team found. In Xcode, select the VibeMeeting target > Signing & Capabilities > Team,"
  echo "then run this script again. Or pass the 10-character Team ID: scripts/save-signing-team.sh ABCDE12345"
  exit 1
fi

printf 'DEVELOPMENT_TEAM = %s\n' "$team" > Configs/Local.xcconfig
echo "Saved Team $team to Configs/Local.xcconfig."
echo "Next: xcodegen generate, build once, then reset the old permission so macOS asks again:"
echo "  tccutil reset AudioCapture $(scripts/bundle-id.sh debug)"
