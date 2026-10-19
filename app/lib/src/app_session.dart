import 'package:flutter/foundation.dart';

import 'api/discovery.dart';
import 'api/family_api.dart';
import 'api/models.dart';
import 'location/location_service.dart';
import 'storage/credential_store.dart';

enum AppRoute { loading, enroll, secureChats, locationExplainer, home }

class AppSession extends ChangeNotifier {
  AppSession({
    CredentialStore? store,
    DiscoveryClient? discovery,
    FamilyApiClient? familyApi,
    LocationService? locationService,
  })  : _store = store ?? SecureCredentialStore(),
        _discovery = discovery ?? DiscoveryClient(),
        _familyApi = familyApi ?? FamilyApiClient(),
        locationService = locationService ?? LocationService();

  final CredentialStore _store;
  final DiscoveryClient _discovery;
  final FamilyApiClient _familyApi;
  final LocationService locationService;

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
    _syncLocationCredentials();
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
    if (await _needsLocationExplainer()) {
      route = AppRoute.locationExplainer;
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
    _syncLocationCredentials();
    pendingEnrollPassword = enrollPassword;
    enrollBannerMessage = null;
    if (bundle.matrixEnrollment.isOk) {
      route = AppRoute.secureChats;
    } else if (await _needsLocationExplainer()) {
      route = AppRoute.locationExplainer;
    } else {
      await _refreshMe(clearOnUnauthorized: false);
    }
    notifyListeners();
  }

  Future<void> finishE2eeSetup({bool skipped = false}) async {
    await _store.setMatrixE2eeSetupComplete(skipped: skipped);
    pendingEnrollPassword = null;
    if (await _needsLocationExplainer()) {
      route = AppRoute.locationExplainer;
      notifyListeners();
      return;
    }
    await _refreshMe(clearOnUnauthorized: false);
  }

  Future<void> acknowledgeLocationSharing() async {
    await _store.setLocationSharingAcknowledged();
    await _startKidLocationSharingIfNeeded();
    await _refreshMe(clearOnUnauthorized: false);
  }

  Future<bool> _needsLocationExplainer() async {
    final bundle = enrollment;
    if (bundle == null || !bundle.isKid) {
      return false;
    }
    final creds = bundle.owntracksCredentials;
    if (creds == null) {
      return false;
    }
    return !(await _store.hasAcknowledgedLocationSharing());
  }

  Future<void> refreshProfile() async {
    await _refreshMe(clearOnUnauthorized: true);
  }

  Future<void> removeDevice() async {
    await locationService.stop();
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
      await _startKidLocationSharingIfNeeded();
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

  void _syncLocationCredentials() {
    locationService.updateCredentials(enrollment?.owntracksCredentials);
  }

  Future<void> _startKidLocationSharingIfNeeded() async {
    final bundle = enrollment;
    if (bundle == null || !bundle.isKid) {
      return;
    }
    if (bundle.owntracksCredentials == null) {
      return;
    }
    if (!(await _store.hasAcknowledgedLocationSharing())) {
      return;
    }
    _syncLocationCredentials();
    if (!locationService.isRunning) {
      await locationService.start();
    }
  }
}
