import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'kid_detail_screen.dart';
import 'one_time_secret_panel.dart';

class MemberDetailScreen extends StatefulWidget {
  const MemberDetailScreen({
    super.key,
    required this.session,
    required this.member,
    this.api,
  });

  final AppSession session;
  final FamilyMember member;
  final FamilyApiClient? api;

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  List<AppDeviceRow> _devices = [];
  bool _loadingDevices = true;
  String? _deviceError;
  bool _busy = false;
  String? _secretTitle;
  String? _secretValue;
  String? _secretHint;
  String? _secretQrPayload;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  EnrollmentBundle? get _bundle => widget.session.enrollment;

  Future<void> _loadDevices() async {
    final bundle = _bundle;
    if (bundle == null) {
      return;
    }
    setState(() {
      _loadingDevices = true;
      _deviceError = null;
    });
    try {
      final devices = await _api.fetchMemberDevices(bundle, widget.member.username);
      setState(() {
        _devices = devices;
        _loadingDevices = false;
      });
    } catch (e) {
      setState(() {
        _loadingDevices = false;
        _deviceError = e.toString();
      });
    }
  }

  Future<void> _resetPassword() async {
    final bundle = _bundle;
    if (bundle == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password?'),
        content: Text(
          'This signs ${widget.member.username} out of every TinyWeb phone '
          'and issues a new password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await _api.resetMemberPassword(bundle, widget.member.username);
      setState(() {
        _busy = false;
        _secretTitle = 'New password';
        _secretValue = result.password;
        _secretHint = 'All app devices for this person were signed out.';
        _secretQrPayload = null;
      });
      await _loadDevices();
    } catch (e) {
      setState(() => _busy = false);
      _showError(e.toString());
    }
  }

  Future<void> _issueEnrollCode() async {
    final bundle = _bundle;
    if (bundle == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await _api.issueMemberEnrollCode(
        bundle,
        widget.member.username,
      );
      setState(() {
        _busy = false;
        _secretTitle = 'TinyWeb app setup';
        _secretValue = result.code;
        _secretHint = 'One-time code for enrolling a new phone.';
        _secretQrPayload = result.qrPayload;
      });
    } catch (e) {
      setState(() => _busy = false);
      _showError(e.toString());
    }
  }

  Future<void> _revokeDevice(AppDeviceRow device) async {
    final bundle = _bundle;
    if (bundle == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove phone?'),
        content: Text(
          'Sign out “${device.deviceName}” (${device.platform})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.revokeMemberDevice(
        bundle,
        widget.member.username,
        device.id,
      );
      setState(() => _busy = false);
      await _loadDevices();
    } catch (e) {
      setState(() => _busy = false);
      _showError(e.toString());
    }
  }

  Future<void> _removeMember() async {
    final bundle = _bundle;
    if (bundle == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove family member?'),
        content: Text(
          'Delete ${widget.member.username} from this home server? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.deleteMember(bundle, widget.member.username);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _busy = false);
      _showError(e.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final isKid = member.role == 'kid';

    return Scaffold(
      appBar: AppBar(title: Text(member.displayLabel)),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  leading: Icon(
                    member.role == 'parent' ? Icons.supervisor_account : Icons.child_care,
                    color: TinyWebColors.blueDeep,
                  ),
                  title: Text(member.username),
                  subtitle: Text(
                    [
                      member.role == 'parent' ? 'Parent' : 'Child',
                      if (member.matrixLabel?.isNotEmpty == true)
                        member.matrixLabel!,
                      if (member.mxid.isNotEmpty) member.mxid,
                    ].join(' · '),
                  ),
                ),
                if (isKid)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.tune),
                      title: const Text('Controls'),
                      subtitle: const Text(
                        'Allowlists, quiet hours, Events access',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => KidDetailScreen(
                              session: widget.session,
                              kid: member,
                              api: widget.api,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (_secretValue != null && _secretTitle != null)
                  OneTimeSecretPanel(
                    title: _secretTitle!,
                    secret: _secretValue!,
                    hint: _secretHint,
                    qrPayload: _secretQrPayload,
                  ),
                const SizedBox(height: 8),
                Text('TinyWeb phones', style: Theme.of(context).textTheme.titleMedium),
                if (_loadingDevices)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_deviceError != null)
                  Text(_deviceError!)
                else if (_devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No phones enrolled yet.'),
                  )
                else
                  ..._devices.map(
                    (d) => Card(
                      child: ListTile(
                        title: Text(d.deviceName),
                        subtitle: Text('${d.platform} · last seen ${d.lastSeenAt ?? "—"}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.phonelink_erase),
                          tooltip: 'Remove phone',
                          onPressed: () => _revokeDevice(d),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _issueEnrollCode,
                  icon: const Icon(Icons.qr_code),
                  label: const Text('Set up TinyWeb on a new phone'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _resetPassword,
                  icon: const Icon(Icons.lock_reset),
                  label: const Text('Reset password'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _removeMember,
                  icon: Icon(Icons.person_remove, color: Theme.of(context).colorScheme.error),
                  label: Text(
                    'Remove from family',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
    );
  }
}
