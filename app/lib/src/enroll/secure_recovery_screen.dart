import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../matrix/matrix_session_opener.dart';

class SecureRecoveryScreen extends StatefulWidget {
  const SecureRecoveryScreen({
    super.key,
    required this.session,
    this.caCertPem,
  });

  final AppSession session;
  final String? caCertPem;

  @override
  State<SecureRecoveryScreen> createState() => _SecureRecoveryScreenState();
}

class _SecureRecoveryScreenState extends State<SecureRecoveryScreen> {
  bool _busy = true;
  String? _error;
  _Flow _flow = _Flow.loading;
  String? _recoveryKey;
  bool _savedChecked = false;
  final _recoveryKeyController = TextEditingController();

  @override
  void dispose() {
    _recoveryKeyController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bundle = widget.session.enrollment;
      if (bundle == null || !bundle.matrixEnrollment.isOk) {
        await widget.session.finishE2eeSetup(skipped: true);
        return;
      }
      final matrix = await openMatrixSession(
        bundle: bundle,
        store: widget.session.credentialStore,
        caCertPem: widget.caCertPem,
      );
      try {
        final status = await matrix.encryptionStatus();

        if (status.recoveryState == 'enabled') {
          await widget.session.finishE2eeSetup();
          return;
        }

        final needsExistingKey = status.recoveryState == 'incomplete' ||
            (status.backupEnabled && status.recoveryState != 'enabled');

        setState(() {
          _flow = needsExistingKey ? _Flow.enterKey : _Flow.createKey;
          _busy = false;
        });
      } finally {
        await releaseMatrixSession(matrix);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _createRecovery() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bundle = widget.session.enrollment!;
      final matrix = await openMatrixSession(
        bundle: bundle,
        store: widget.session.credentialStore,
        caCertPem: widget.caCertPem,
      );
      try {
        final key = await matrix.setupRecovery(
          password: widget.session.pendingEnrollPassword,
        );
        await widget.session.credentialStore.writeMatrixRecoveryKey(key);
        setState(() {
          _recoveryKey = key;
          _flow = _Flow.showKey;
          _busy = false;
        });
      } finally {
        await releaseMatrixSession(matrix);
      }
    } catch (e) {
      final text = e.toString();
      if (text.contains('needs_recovery_key:')) {
        setState(() {
          _flow = _Flow.enterKey;
          _error =
              'Another device already set up recovery. Enter your recovery key below.';
          _busy = false;
        });
      } else {
        setState(() {
          _error = text;
          _busy = false;
        });
      }
    }
  }

  Future<void> _recoverFromKey() async {
    final key = _recoveryKeyController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Enter your recovery key');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bundle = widget.session.enrollment!;
      final matrix = await openMatrixSession(
        bundle: bundle,
        store: widget.session.credentialStore,
        caCertPem: widget.caCertPem,
      );
      try {
        await matrix.recover(recoveryKey: key);
        await widget.session.credentialStore.writeMatrixRecoveryKey(key);
        await widget.session.finishE2eeSetup();
      } finally {
        await releaseMatrixSession(matrix);
      }
    } catch (e) {
      setState(() {
        _error = 'Could not recover: $e';
        _busy = false;
      });
    }
  }

  Future<void> _skip() async {
    await widget.session.finishE2eeSetup(skipped: true);
  }

  Future<void> _confirmSaved() async {
    if (!_savedChecked) {
      return;
    }
    await widget.session.finishE2eeSetup();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Secure your chats')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'End-to-end encryption',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Messages are encrypted on this device. Save a recovery key so you can read '
                  'older messages if you sign in on a new phone.',
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                switch (_flow) {
                  _Flow.loading => const SizedBox.shrink(),
                  _Flow.createKey => FilledButton(
                      onPressed: _createRecovery,
                      child: const Text('Create recovery key'),
                    ),
                  _Flow.showKey => _ShowKeyPanel(
                      recoveryKey: _recoveryKey!,
                      savedChecked: _savedChecked,
                      onSavedChanged: (v) => setState(() => _savedChecked = v),
                      onContinue: _confirmSaved,
                    ),
                  _Flow.enterKey => _EnterKeyPanel(
                      controller: _recoveryKeyController,
                      onRecover: _recoverFromKey,
                      onSkip: _skip,
                    ),
                },
              ],
            ),
    );
  }
}

enum _Flow { loading, createKey, showKey, enterKey }

class _ShowKeyPanel extends StatelessWidget {
  const _ShowKeyPanel({
    required this.recoveryKey,
    required this.savedChecked,
    required this.onSavedChanged,
    required this.onContinue,
  });

  final String recoveryKey;
  final bool savedChecked;
  final ValueChanged<bool> onSavedChanged;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Save this recovery key in a safe place (password manager or paper). '
          'TinyWeb can show it again in Settings on this device.',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 12),
        SelectableText(
          recoveryKey,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: recoveryKey));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Recovery key copied')),
            );
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy recovery key'),
        ),
        CheckboxListTile(
          value: savedChecked,
          onChanged: (v) => onSavedChanged(v ?? false),
          title: const Text('I saved my recovery key'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton(
          onPressed: savedChecked ? onContinue : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _EnterKeyPanel extends StatelessWidget {
  const _EnterKeyPanel({
    required this.controller,
    required this.onRecover,
    required this.onSkip,
  });

  final TextEditingController controller;
  final VoidCallback onRecover;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Recovery is already set up on another device. Enter the recovery key to '
          'unlock message history on this phone.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Recovery key',
            border: OutlineInputBorder(),
          ),
          autocorrect: false,
          minLines: 2,
          maxLines: 4,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRecover, child: const Text('Recover')),
        TextButton(onPressed: onSkip, child: const Text('Skip for now')),
        const SizedBox(height: 8),
        Text(
          'If you skip, only new messages will be readable until you enter a recovery key.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
