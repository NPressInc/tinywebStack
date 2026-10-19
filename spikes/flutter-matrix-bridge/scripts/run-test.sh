#!/usr/bin/env bash
set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SPIKE_ROOT"

source "${HOME}/.cargo/env"
export PATH="${HOME}/sdk/flutter/bin:${PATH}"

echo "Building Rust library (release)…"
cargo build --release --manifest-path rust/Cargo.toml

export TW_HS="${TW_HS:-https://family-b.family.test}"
export TW_CA_FILE="${TW_CA_FILE:-${HOME}/.tinywebstack-secrets/lab-ca/lab-ca.crt.pem}"
export TW_USER_A="${TW_USER_A:-bob}"
export TW_USER_B="${TW_USER_B:-alice}"
export TW_LIB="${TW_LIB:-${SPIKE_ROOT}/rust/target/release/librust_lib_tw_matrix_spike.so}"

if [[ -z "${TW_TEST_PASSWORD:-}" ]]; then
  echo "TW_TEST_PASSWORD must be set in the environment." >&2
  exit 1
fi

flutter test test/matrix_bridge_test.dart
