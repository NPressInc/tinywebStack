#!/usr/bin/env bash
# Build a lab-trust APK for physical Android testing (arm64).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"

CA_FILE="${TW_LAB_CA_FILE:-$HOME/.tinywebstack-secrets/lab-ca/lab-ca.crt.pem}"
OUT_DIR="${TW_LAB_APK_DIR:-$HOME/tinyweb-phone}"
OUT_APK="${OUT_DIR}/tinyweb-lab.apk"
APP_DIR="${TW_STACK_ROOT}/app"

require_cmd base64
require_cmd tr

if [[ ! -f "$CA_FILE" ]]; then
  die "Lab CA not found at ${CA_FILE} (set TW_LAB_CA_FILE)"
fi

export PATH="${HOME}/sdk/flutter/bin:${PATH:-}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"

LAB_CA_B64="$(base64 < "$CA_FILE" | tr -d '\n')"
DART_DEFINE=(--dart-define="TW_LAB_CA_PEM_B64=${LAB_CA_B64}")

log "Building lab APK (CA from ${CA_FILE})"
cd "$APP_DIR"
flutter pub get

BUILD_MODE=release
if ! flutter build apk --release --target-platform android-arm64 "${DART_DEFINE[@]}" 2>/tmp/tws-lab-apk-release.log; then
  log "WARN: release APK failed on this host (see /tmp/tws-lab-apk-release.log); trying debug"
  BUILD_MODE=debug
  flutter build apk --debug --target-platform android-arm64 "${DART_DEFINE[@]}"
fi

SRC_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-${BUILD_MODE}.apk"
mkdir -p "$OUT_DIR"
cp -f "$SRC_APK" "$OUT_APK"
log "Wrote ${OUT_APK} (${BUILD_MODE})"
