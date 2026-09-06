#!/bin/bash
set -euo pipefail

app_path=${1:?Usage: sign-release.sh APP_PATH DEVELOPER_ID_IDENTITY}
signing_identity=${2:?Pass a Developer ID Application identity}
case "$signing_identity" in
  'Developer ID Application: '*) ;;
  *) echo 'A Developer ID Application identity is required.' >&2; exit 1 ;;
esac
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
[[ "$bundle_id" == 'com.connectedmate.codenotch-accounts' ]] || { echo 'Unexpected application bundle.' >&2; exit 1; }

sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"
sign_code() {
  /usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$@"
}

# Nested code must be signed before its enclosing bundle. The downloader can
# carry its own sandbox entitlements; these never belong on the main app.
sign_code "$sparkle_path/Versions/B/XPCServices/Installer.xpc"
sign_code --preserve-metadata=entitlements "$sparkle_path/Versions/B/XPCServices/Downloader.xpc"
sign_code "$sparkle_path/Versions/B/Autoupdate"
sign_code "$sparkle_path/Versions/B/Updater.app"
sign_code "$sparkle_path"
sign_code "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
