#!/usr/bin/env bash
# Build a Play App Bundle with the local upload key. Does not upload.
# CI does not run this script. See docs/APP_STORES.md.
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "This script takes no arguments and does not accept keystore passwords." >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${root}/app"
props="${app}/android/key.properties"

if [[ ! -f "${props}" ]]; then
  echo "Missing ${props}." >&2
  echo "Copy app/android/key.properties.example and fill it locally. Never commit it." >&2
  exit 1
fi

require_prop() {
  local key="$1"
  if ! grep -Eq "^${key}=.+" "${props}"; then
    echo "android/key.properties is missing a non-empty ${key}." >&2
    echo "Refusing to build a Play bundle with the debug key." >&2
    exit 1
  fi
}

require_prop storeFile
require_prop storePassword
require_prop keyAlias
require_prop keyPassword

cd "${app}" || exit 1
flutter build appbundle --release
echo "AAB output is ${app}/build/app/outputs/bundle/release/app-release.aab"
echo "This script does not upload to Google Play."
