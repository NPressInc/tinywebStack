#!/usr/bin/env bash
# Run push lab test on the control machine (never prints secrets).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${TW_STACK_ROOT}/app"
TEST_REL=${1:-lab_test/push_test.dart}

[[ -d "$APP_DIR" ]] || { echo "Missing app dir" >&2; exit 1; }
cd "$APP_DIR"
flutter test "$TEST_REL"
