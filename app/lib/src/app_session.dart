import 'package:flutter/foundation.dart';

import 'api/discovery.dart';
import 'api/family_api.dart';
import 'api/models.dart';
import 'storage/credential_store.dart';

enum AppRoute { loading, enroll, secureChats, home }

class AppSession extends ChangeNotifier {
  AppSession({
    CredentialStore? store,
    DiscoveryClient? discovery,
    FamilyApiClient? familyApi,
  })  : _store = store ?? SecureCredentialStore(),
        _discovery = discovery ?? DiscoveryClient(),
        _familyApi = familyApi ?? FamilyApiClient();

  final CredentialStore _store;
  final DiscoveryClient _discovery;
  final FamilyApiClient _familyApi;

  AppRoute route = AppRoute.loading;
  EnrollmentBundle? enrollment;
  AppMeProfile? profile;
  String? enrollBannerMessage;

  /// Matrix account password from password enrollment only; used once for recovery setup.
  String? pendingEnrollPassword;

  CredentialStore get credentialStore => _store;

  bool get isLoading => route == AppRoute.loading;

  Future<void> bootstrap() async {
    enrollBannerMessage = null;
    pendingEnrollPassword = null;
    enrollment = await _store.read();
    if (enrollment == null) {
      route = AppRoute.enroll;
      notifyListeners();
      return;
    }
    if (await _needsE2eeSetup()) {
      route = AppRoute.secureChats;
      notifyListeners();
      return;
    }
    await _refreshMe(clearOnUnauthorized: true);
  }

  Future<bool> _needsE2eeSetup() async {
    final bundle = enrollment;
    if (bundle == null || !bundle.matrixEnrollment.isOk) {
      return false;
    }
    return !(await _store.isMatrixE2eeSetupComplete());
  }

  Future<void> completeEnrollment(
    EnrollmentBundle bundle, {
    String? enrollPassword,
  }) async {
    await _store.ensureMatrixStorePassphrase();
    await _store.write(bundle);
    enrollment = bundle;
    pendingEnrollPassword = enrollPassword;
    enrollBannerMessage = null;
    if (bundle.matrixEnrollment.isOk) {
      route = AppRoute.secureChats;
    } else {
      await _refreshMe(clearOnUnauthorized: false);
    }
    notifyListeners();
  }

  Future<void> finishE2eeSetup({bool skipped = false}) async {
    await _store.setMatrixE2eeSetupComplete(skipped: skipped);
    pendingEnrollPassword = null;
    await _refreshMe(clearOnUnauthorized: false);
  }

  Future<void> refreshProfile() async {
    await _refreshMe(clearOnUnauthorized: true);
  }

  Future<void> removeDevice() async {
    await _store.clear();
    enrollment = null;
    profile = null;
    pendingEnrollPassword = null;
    route = AppRoute.enroll;
    notifyListeners();
  }

  Future<FamilyDiscovery> discoverServer(String serverOrigin) {
    return _discovery.fetch(serverOrigin);
  }

  Future<EnrollmentBundle> enrollWithCode({
    required FamilyDiscovery discovery,
    required String code,
  }) {
    return _familyApi.enroll(
      discovery: discovery,
      method: 'code',
      code: code,
    );
  }

  Future<EnrollmentBundle> enrollWithPassword({
    required FamilyDiscovery discovery,
    required String username,
    required String password,
  }) {
    return _familyApi.enroll(
      discovery: discovery,
      method: 'password',
      username: username,
      password: password,
    );
  }

  Future<void> _refreshMe({required bool clearOnUnauthorized}) async {
    final bundle = enrollment;
    if (bundle == null) {
      route = AppRoute.enroll;
      notifyListeners();
      return;
    }
    try {
      profile = await _familyApi.fetchMe(bundle);
      route = AppRoute.home;
    } on EnrollException catch (e) {
      if (clearOnUnauthorized &&
          e.kind == EnrollErrorKind.invalidCredentials) {
        await _store.clear();
        enrollment = null;
        profile = null;
        enrollBannerMessage = e.message ??
            'This device was removed from your family. Please enroll again.';
        route = AppRoute.enroll;
      } else {
        rethrow;
      }
    }
    notifyListeners();
  }
}
