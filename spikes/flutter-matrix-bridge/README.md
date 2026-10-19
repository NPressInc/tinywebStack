# Spike: Flutter ↔ matrix-rust-sdk bridge

Throwaway spike for the TinyWeb app stack decision (see `docs/TINYWEB_APP_PLAN.md`).
Results and recommendation: **[FINDINGS.md](FINDINGS.md)**. Codegen notes: [NOTES-codegen.md](NOTES-codegen.md). Raw output: [TEST-OUTPUT.txt](TEST-OUTPUT.txt).

```bash
# Rust facade: rust/src/api/matrix.rs   Dart test: test/matrix_bridge_test.dart
TW_TEST_PASSWORD=… ./scripts/run-test.sh                      # lab tws-family-b (default)
TW_HS=http://localhost:18008 TW_CA_FILE= TW_TEST_PASSWORD=… ./scripts/run-test.sh   # any other Synapse
```
