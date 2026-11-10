import '../api/models.dart';

class SetupCheckItem {
  const SetupCheckItem({
    required this.title,
    required this.detail,
    required this.ready,
  });

  final String title;
  final String detail;
  final bool ready;
}

class SetupChecklist {
  const SetupChecklist({
    required this.headline,
    required this.subtitle,
    required this.items,
    required this.remaining,
    required this.continueLabel,
  });

  final String headline;
  final String subtitle;
  final List<SetupCheckItem> items;
  final String? remaining;
  final String continueLabel;
}

String? _sectionStatus(EnrollmentBundle bundle, String key) {
  final raw = bundle.rawJson?[key];
  if (raw is Map<String, dynamic>) {
    return raw['status'] as String?;
  }
  return null;
}

/// What the phone linked from the enrollment bundle, plus any step still left.
SetupChecklist describeSetup(
  EnrollmentBundle bundle, {
  required bool needsRecovery,
  required bool needsLocation,
}) {
  final items = <SetupCheckItem>[];
  final remaining = <String>[];

  if (bundle.matrixEnrollment.isOk) {
    items.add(
      const SetupCheckItem(
        title: 'Chat',
        detail: 'Signed in on this phone.',
        ready: true,
      ),
    );
  } else {
    items.add(
      const SetupCheckItem(
        title: 'Chat',
        detail:
            'Not linked yet. Ask a parent for a new code, or use Password on the sign-in screen.',
        ready: false,
      ),
    );
    remaining.add(
      'Chat did not link. Ask a parent for a new code, or sign in with the account password.',
    );
  }

  if (bundle.caldavCredentials != null) {
    items.add(
      const SetupCheckItem(
        title: 'Calendar',
        detail: 'Linked on this phone.',
        ready: true,
      ),
    );
  } else {
    items.add(
      const SetupCheckItem(
        title: 'Calendar',
        detail: 'Not linked yet. Ask a parent to try phone setup again.',
        ready: false,
      ),
    );
    remaining.add('Calendar did not link. Ask a parent to create a new setup code.');
  }

  final eventsStatus = _sectionStatus(bundle, 'mobilizon');
  if (bundle.mobilizonCredentials != null) {
    items.add(
      const SetupCheckItem(
        title: 'Events',
        detail: 'Linked on this phone.',
        ready: true,
      ),
    );
  } else if (eventsStatus == 'password_required') {
    items.add(
      const SetupCheckItem(
        title: 'Events',
        detail:
            'Not linked yet. Open the Events tab and enter the family password once. That password is not in the QR code.',
        ready: false,
      ),
    );
    remaining.add(
      'Events still need the family password once. Open the Events tab and enter it. The QR code does not include that password.',
    );
  } else {
    items.add(
      const SetupCheckItem(
        title: 'Events',
        detail: 'Not used on this family box.',
        ready: true,
      ),
    );
  }

  final locationStatus = _sectionStatus(bundle, 'owntracks');
  if (bundle.isKid && bundle.owntracksCredentials != null) {
    items.add(
      SetupCheckItem(
        title: 'Location',
        detail: needsLocation
            ? (needsRecovery
                ? 'Ready. After you save the chat recovery key, the app asks you to allow location so parents can see this phone.'
                : 'Ready. The next screen asks you to allow location so parents can see this phone.')
            : 'Sharing is set up on this phone.',
        ready: true,
      ),
    );
  } else if (bundle.isKid && locationStatus == 'unavailable') {
    items.add(
      const SetupCheckItem(
        title: 'Location',
        detail: 'Not linked yet. A parent can open Location phone setup and try again.',
        ready: false,
      ),
    );
    remaining.add(
      'Location did not link. A parent can open this person on the family dashboard and try setup again.',
    );
  } else if (!bundle.isKid) {
    items.add(
      const SetupCheckItem(
        title: 'Location',
        detail: 'Parents view the family map. This phone does not publish its location.',
        ready: true,
      ),
    );
  } else {
    items.add(
      const SetupCheckItem(
        title: 'Location',
        detail: 'Not set up for this account.',
        ready: true,
      ),
    );
  }

  if (needsRecovery) {
    remaining.insert(
      0,
      'Save the chat recovery key on the next screen. Without it, this phone cannot read older encrypted messages.',
    );
  }
  if (needsLocation) {
    remaining.add(
      'Allow location on the next screen so parents can see this phone on your family\'s own server.',
    );
  }

  final continueLabel = needsRecovery
      ? 'Continue — save chat recovery key'
      : needsLocation
          ? 'Continue — allow location'
          : 'Continue';
  final server =
      bundle.serverName.isNotEmpty ? bundle.serverName : bundle.serverOrigin;
  return SetupChecklist(
    headline: "You're all set",
    subtitle: 'Signed in as ${bundle.username} on $server.',
    items: items,
    remaining: remaining.isEmpty ? null : remaining.join(' '),
    continueLabel: continueLabel,
  );
}
