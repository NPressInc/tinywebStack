import 'package:flutter/material.dart';
import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import '../enroll/enroll_screen.dart' show defaultEnrollQrScanner, EnrollQrScannerBuilder;
import 'link_invite_token.dart';

class AcceptLinkInviteScreen extends StatefulWidget {
  const AcceptLinkInviteScreen({
    super.key,
    required this.session,
    this.api,
    this.qrScannerBuilder = defaultEnrollQrScanner,
  });

  final AppSession session;
  final FamilyApiClient? api;
  final EnrollQrScannerBuilder qrScannerBuilder;

  @override
  State<AcceptLinkInviteScreen> createState() => _AcceptLinkInviteScreenState();
}

class _AcceptLinkInviteScreenState extends State<AcceptLinkInviteScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  final _tokenController = TextEditingController();
  bool _scanning = false;
  bool _busy = false;
  String? _error;
  LinkInvitePreview? _preview;
  LinkInviteAcceptResult? _acceptResult;

  @override
  void dispose() {
    _tokenController.dispose();
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  void _onScan(String raw) {
    final token = parseLinkInviteToken(raw);
    if (token == null) {
      return;
    }
    _tokenController.text = token;
    setState(() {
      _scanning = false;
      _preview = null;
      _acceptResult = null;
      _error = null;
    });
    _loadPreview(token);
  }

  Future<void> _loadPreview([String? tokenOverride]) async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    final token = parseLinkInviteToken(tokenOverride ?? _tokenController.text);
    if (token == null || token.isEmpty) {
      setState(() => _error = 'Paste or scan an invite token.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _acceptResult = null;
    });
    try {
      final preview = await _api.previewLinkInvite(bundle, token);
      setState(() {
        _preview = preview;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _accept() async {
    final bundle = widget.session.enrollment;
    final token = parseLinkInviteToken(_tokenController.text);
    if (bundle == null || token == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.acceptLinkInvite(bundle, token);
      setState(() {
        _acceptResult = result;
        _preview = null;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _decline() async {
    final bundle = widget.session.enrollment;
    final token = parseLinkInviteToken(_tokenController.text);
    if (bundle == null || token == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.declineLinkInvite(bundle, token);
      if (mounted) {
        Navigator.of(context).pop(false);
      }
    } catch (e) {
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final text = e.toString().toLowerCase();
    if (text.contains('expired')) {
      return 'This invite has expired. Ask the other household for a new one.';
    }
    if (text.contains('already used')) {
      return 'This invite was already used.';
    }
    if (text.contains('yourself') || text.contains('cannot link')) {
      return 'You cannot link your household to itself.';
    }
    if (text.contains('could not reach') || text.contains('unreachable')) {
      return 'Could not reach the inviting household. Check network and try again.';
    }
    if (text.contains('already linked')) {
      return 'You are already linked with this household.';
    }
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accept an invite')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_scanning) ...[
            SizedBox(
              height: 220,
              child: widget.qrScannerBuilder(onDetect: _onScan),
            ),
            TextButton(
              onPressed: () => setState(() => _scanning = false),
              child: const Text('Cancel scan'),
            ),
          ] else ...[
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Invite token',
                hintText: 'Paste token or invite link',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => setState(() => _scanning = true),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _loadPreview(),
                  child: const Text('Preview'),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_preview != null && !_busy) ...[
            const SizedBox(height: 24),
            _PreviewCard(preview: _preview!),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _decline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _preview!.alreadyLinked ? null : _accept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
          if (_acceptResult != null) ...[
            const SizedBox(height: 24),
            _ResultCard(result: _acceptResult!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Done'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.preview});

  final LinkInvitePreview preview;

  @override
  Widget build(BuildContext context) {
    final expiry = preview.expiresAtUtc?.toLocal();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preview.inviterFamilyName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(preview.inviterDomain, style: Theme.of(context).textTheme.bodyMedium),
            if (expiry != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Expires ${expiry.toString().substring(0, 16)}'),
              ),
            if (!preview.reachable)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Inviting household is not reachable right now; you can still try to accept.',
                  style: TextStyle(color: Colors.orange),
                ),
              ),
            if (preview.alreadyLinked)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Already linked with this household.'),
              ),
            const SizedBox(height: 12),
            const Text(
              'Linking enables chat between households and shares PUBLIC events on Mobilizon.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final LinkInviteAcceptResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: TinyWebColors.blueDeep.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.alreadyLinked ? 'Already linked' : 'Linked',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('Domain: ${result.linkedDomain}'),
            Text('Matrix federation: ${result.synapseFederation}'),
            Text('Mobilizon relay: ${result.mobilizonRelay}'),
          ],
        ),
      ),
    );
  }
}
