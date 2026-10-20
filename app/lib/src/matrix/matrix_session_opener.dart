import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../matrix_core.dart';
import '../rust/api/matrix.dart' as rust;
import '../storage/credential_store.dart';

Future<String> matrixStoreDirectory() async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/matrix';
}

Future<rust.MatrixSession> openMatrixSession({
  required EnrollmentBundle bundle,
  required CredentialStore store,
  String? caCertPem,
}) async {
  await MatrixCore.instance.ensureInitialized();
  final creds = bundle.matrixEnrollment;
  if (!creds.isOk) {
    throw StateError('Matrix not configured');
  }
  final passphrase = await store.readMatrixStorePassphrase();
  final storeDir = await matrixStoreDirectory();
  final session = await rust.restoreSession(
    homeserverUrl: creds.homeserver!,
    userId: creds.userId!,
    deviceId: creds.deviceId!,
    accessToken: creds.accessToken!,
    storeDir: storeDir,
    storePassphrase: passphrase,
    caCertPem: caCertPem,
  );
  await session.syncOnce();
  return session;
}

/// Stops sync and releases the native session (drops the Matrix SDK client on the Rust runtime).
Future<void> releaseMatrixSession(rust.MatrixSession session) async {
  await session.stopSync();
  session.dispose();
}
