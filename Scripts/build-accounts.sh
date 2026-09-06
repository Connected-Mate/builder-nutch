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
xcodebuild -project Codenotch.xcodeproj -scheme Codenotch \
  -destination 'platform=macOS' -configuration Release \
  -derivedDataPath build/AccountsDerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO "$ACTION"
