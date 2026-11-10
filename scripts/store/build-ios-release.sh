#!/usr/bin/env bash
# Build an App Store IPA on a Mac. Does not upload.
# CI does not run this script. See docs/APP_STORES.md.
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "This script takes no arguments and does not accept certificates or passwords." >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS store builds need a Mac with Xcode and the Apple Distribution certificate for team RC44X9237L in the keychain." >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${root}/app"
plist="${app}/ios/ExportOptions.plist"

if [[ ! -f "${plist}" ]]; then
  echo "Missing ${plist}" >&2
  exit 1
fi

if ! grep -q "RC44X9237L" "${plist}"; then
  echo "ExportOptions.plist is missing team RC44X9237L" >&2
  exit 1
fi

cd "${app}" || exit 1
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
echo "IPA output is under ${app}/build/ios/ipa"
echo "This script does not upload to App Store Connect."
