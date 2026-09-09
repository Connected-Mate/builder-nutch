#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=2.46.0
XCODEGEN="$ROOT/.tools/xcodegen.artifactbundle/xcodegen-$VERSION-macosx/bin/xcodegen"
if [ ! -x "$XCODEGEN" ]; then
  mkdir -p .tools
  ARCHIVE=$(mktemp /tmp/codenotch-xcodegen.XXXXXX)
  curl -fL --proto '=https' --tlsv1.2 "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.artifactbundle.zip" -o "$ARCHIVE"
  ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
  test "$ACTUAL" = ef6d0a23bfb7393387f98e321ffd78a487231172e2e78c48d3c26275c263fd0c || { echo 'XcodeGen checksum mismatch.' >&2; exit 1; }
  unzip -q "$ARCHIVE" -d .tools
fi
"$XCODEGEN" generate
ACTION=${1:-build}
case "$ACTION" in
  build|test) ;;
  *) echo 'Usage: Scripts/build-accounts.sh [build|test]' >&2; exit 2 ;;
esac
# Rebuilding an installed signed app must retain its identity: an ad-hoc
# replacement loses its Keychain access and cannot load hardened frameworks.
# Only reuse an installed Developer ID when its private identity is available.
SIGNING_IDENTITY=${CODENOTCH_SIGNING_IDENTITY:-}
if [ -z "$SIGNING_IDENTITY" ] && [ -d '/Applications/Builder Nutch.app' ]; then
  INSTALLED_IDENTITY=$(/usr/bin/codesign -dvv '/Applications/Builder Nutch.app' 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -n 1) || INSTALLED_IDENTITY=''
  if [ -n "$INSTALLED_IDENTITY" ] && /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq -- "\"$INSTALLED_IDENTITY\""; then
    SIGNING_IDENTITY=$INSTALLED_IDENTITY
  fi
fi
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
if [ "$ACTION" = test ]; then
  # @testable imports require Debug's testability. Tests execute on this Mac's
  # architecture and use a separate directory from the distributable build.
  xcodebuild -project Codenotch.xcodeproj -scheme Codenotch \
    -destination "platform=macOS,arch=$(uname -m)" -configuration Debug \
    -derivedDataPath build/TestsDerivedData \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGNING_REQUIRED=NO test
else
  xcodebuild -project Codenotch.xcodeproj -scheme Codenotch \
    -destination 'platform=macOS' -configuration Release \
    -derivedDataPath build/AccountsDerivedData \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGNING_REQUIRED=NO \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
  case "$SIGNING_IDENTITY" in
    'Developer ID Application: '*)
      ./Scripts/sign-release.sh 'build/AccountsDerivedData/Build/Products/Release/Builder Nutch.app' "$SIGNING_IDENTITY"
      ;;
  esac
fi
