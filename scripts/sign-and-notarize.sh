#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_PATH FINAL_ARCHIVE_PATH" >&2
  exit 64
fi

app_path=$1
final_archive_path=$2
final_dmg_path="${final_archive_path%.zip}.dmg"
notarization_archive_path="${final_archive_path%.zip}.notarization.zip"
signing_identity=${MACOS_SIGNING_IDENTITY:?MACOS_SIGNING_IDENTITY is required}
: "${APPLE_API_PRIVATE_KEY_PATH:?APPLE_API_PRIVATE_KEY_PATH is required}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"

if [ ! -d "$app_path" ]; then
  echo "app not found: $app_path" >&2
  exit 66
fi

mkdir -p "$(dirname "$final_archive_path")"
rm -f "$final_archive_path" "$final_dmg_path" "$notarization_archive_path"

# Sparkle's distribution includes nested XPC services and helper executables.
# Sign each component inside out with our Developer ID before signing the app.
# The Downloader service's entitlements must survive re-signing.
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$sparkle_framework" ]; then
  echo "Sparkle.framework is missing from $app_path" >&2
  exit 66
fi
sparkle_contents="$sparkle_framework/Versions/B"
codesign --force --options runtime --timestamp --sign "$signing_identity" \
  "$sparkle_contents/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "$signing_identity" "$sparkle_contents/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$signing_identity" \
  "$sparkle_contents/Autoupdate"
codesign --force --options runtime --timestamp --sign "$signing_identity" \
  "$sparkle_contents/Updater.app"
codesign --force --options runtime --timestamp --sign "$signing_identity" \
  "$sparkle_framework"

echo "Signing $app_path with $signing_identity"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$signing_identity" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign_details=$(codesign -dvvv "$app_path" 2>&1)
printf '%s\n' "$codesign_details" | grep -q 'Authority=Developer ID Application:'
printf '%s\n' "$codesign_details" | grep -q 'Timestamp='

echo "Creating notarization archive $notarization_archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notarization_archive_path"

notarize_file() {
  local file_path=$1
  echo "Submitting $file_path with xcrun notarytool"
  submission=$(xcrun notarytool submit "$file_path" \
    --key "$APPLE_API_PRIVATE_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --output-format json)
  printf '%s\n' "$submission"

  # Assert the verdict rather than only printing it. `stapler staple` below
  # would fail anyway, but a rejection should say why, and should fetch the
  # per-issue log while the submission id is still in hand.
  notarization_status=$(printf '%s\n' "$submission" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
  if [ "$notarization_status" != "Accepted" ]; then
    echo "notarization was not accepted (status: ${notarization_status:-unknown})" >&2
    submission_id=$(printf '%s\n' "$submission" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
    if [ -n "$submission_id" ]; then
      echo "notarization log for $submission_id:" >&2
      xcrun notarytool log "$submission_id" \
        --key "$APPLE_API_PRIVATE_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" >&2 || true
    fi
    exit 65
  fi
}

notarize_file "$notarization_archive_path"

echo "Stapling notarization ticket"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

echo "Creating notarized archive $final_archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_archive_path"

echo "Creating, signing, and notarizing $final_dmg_path"
hdiutil create -volname SparkBar -srcfolder "$app_path" -fs APFS -format ULFO -ov "$final_dmg_path"
codesign --force --timestamp --sign "$signing_identity" "$final_dmg_path"
notarize_file "$final_dmg_path"
xcrun stapler staple "$final_dmg_path"
xcrun stapler validate "$final_dmg_path"
rm -f "$notarization_archive_path"

echo "Notarized $final_archive_path and $final_dmg_path"
