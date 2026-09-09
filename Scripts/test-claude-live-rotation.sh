#!/bin/bash
# Opt-in macOS integration proof: actual CLI, dummy Keychain items, loopback only.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cli=${1:-"$HOME/.local/bin/claude"}
[[ -x "$cli" ]] || { echo "Claude executable missing: $cli" >&2; exit 1; }
fixture=$(mktemp -d "${TMPDIR:-/tmp}/claude-live-rotation-XXXXXXXX")
chmod 700 "$fixture"
# Fixture retained for evidence; Python never logs credential material beyond TEST-ONLY labels.
xcrun swiftc -o "$fixture/rotation-harness" \
  "$repo/Scripts/ClaudeLiveRotationHarness.swift" \
  "$repo/Sources/Accounts/ClaudeSystemCredentials.swift" \
  "$repo/Sources/Accounts/ClaudeSecurityToolKeychain.swift" \
  "$repo/Sources/Accounts/ClaudeTokenRefresh.swift" \
  "$repo/Sources/Accounts/KeychainInteraction.swift" \
  "$repo/Sources/Providers/KeychainItem.swift" \
  "$repo/Sources/Providers/ClaudeProfile.swift"
codesign --force --sign "Developer ID Application: Connected Mate (523L8BHNF8)" "$fixture/rotation-harness"
"$fixture/rotation-harness" "$fixture" "$repo/Scripts/test-claude-rotation-server.py" "$cli"
echo "Proof: $fixture/proof.json"
