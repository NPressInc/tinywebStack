import 'package:tinyweb/src/rust/frb_generated.dart';

/// Lazy wrapper so widget tests never load the native Matrix library.
class MatrixCore {
  MatrixCore._();

  static final MatrixCore instance = MatrixCore._();

  bool _initialized = false;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }
    await RustLib.init();
    _initialized = true;
  }
}
