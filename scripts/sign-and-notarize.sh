#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_PATH FINAL_ARCHIVE_PATH" >&2
  exit 64
fi

app_path=$1
final_archive_path=$2
notarization_archive_path="${final_archive_path%.zip}.notarization.zip"
signing_identity=${MACOS_SIGNING_IDENTITY:?MACOS_SIGNING_IDENTITY is required}

if [ ! -d "$app_path" ]; then
  echo "app not found: $app_path" >&2
  exit 66
fi

mkdir -p "$(dirname "$final_archive_path")"
rm -f "$final_archive_path" "$notarization_archive_path"

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

if [ -n "${APPLE_API_PRIVATE_KEY_PATH:-}" ]; then
  : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required with APPLE_API_PRIVATE_KEY_PATH}"
  : "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required with APPLE_API_PRIVATE_KEY_PATH}"

  echo "Submitting archive with xcrun notarytool"
  xcrun notarytool submit "$notarization_archive_path" \
    --key "$APPLE_API_PRIVATE_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --output-format json
elif command -v asc >/dev/null 2>&1; then
  echo "Submitting archive with asc"
  asc notarization submit --file "$notarization_archive_path" --wait
else
  echo "notarization credentials are missing: provide APPLE_API_PRIVATE_KEY_PATH or configure asc" >&2
  exit 78
fi

echo "Stapling notarization ticket"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

echo "Creating notarized archive $final_archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_archive_path"
rm -f "$notarization_archive_path"

echo "Notarized $final_archive_path"
