import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'enroll_link.dart';

typedef EnrollQrScannerBuilder = Widget Function({
  required void Function(String raw) onDetect,
});

Widget defaultEnrollQrScanner({required void Function(String raw) onDetect}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: MobileScanner(
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final raw = barcode.rawValue;
          if (raw != null && raw.isNotEmpty) {
            onDetect(raw);
            return;
          }
        }
      },
    ),
  );
}

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({
    super.key,
    required this.session,
    this.bannerMessage,
    this.qrScannerBuilder = defaultEnrollQrScanner,
  });

  final AppSession session;
  final String? bannerMessage;
  final EnrollQrScannerBuilder qrScannerBuilder;

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _serverController = TextEditingController();
  final _codeController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  _EnrollMode _mode = _EnrollMode.code;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _applyScan(String raw) {
    final parsed = parseEnrollLink(raw);
    if (parsed.serverOrigin != null) {
      _serverController.text = parsed.serverHost ?? parsed.serverOrigin!;
    }
    if (parsed.code != null) {
      _codeController.text = parsed.code!;
      _mode = _EnrollMode.code;
    } else if (parsed.code == null && !raw.contains('://')) {
      _codeController.text = raw;
    }
    setState(() {});
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final origin = normalizeServerOrigin(_serverController.text);
      if (origin == null) {
        throw EnrollException(
          EnrollErrorKind.network,
          'Enter a valid HTTPS server (e.g. family.example)',
        );
      }

      final discovery = await widget.session.discoverServer(origin);

      final EnrollmentBundle bundle;
      if (_mode == _EnrollMode.code) {
        final code = _codeController.text.trim();
        if (code.isEmpty) {
          throw EnrollException(EnrollErrorKind.network, 'Enter an enroll code');
        }
        bundle = await widget.session.enrollWithCode(
          discovery: discovery,
          code: code,
        );
      } else {
        bundle = await widget.session.enrollWithPassword(
          discovery: discovery,
          username: _usernameController.text.trim(),
          password: _passwordController.text,
        );
      }

      await widget.session.completeEnrollment(
        bundle,
        enrollPassword:
            _mode == _EnrollMode.password ? _passwordController.text : null,
      );
    } on EnrollException catch (e) {
      setState(() => _error = _messageFor(e));
    } catch (_) {
      setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _messageFor(EnrollException e) {
    switch (e.kind) {
      case EnrollErrorKind.invalidCredentials:
        return e.message ?? 'Invalid username or password';
      case EnrollErrorKind.notFamilyMember:
        return 'This account is not a family member on this box';
      case EnrollErrorKind.rateLimited:
        return 'Too many attempts. Wait a moment and try again.';
      case EnrollErrorKind.needsUpdate:
        return e.message ?? 'This TinyWeb box needs an update';
      case EnrollErrorKind.network:
      case EnrollErrorKind.server:
        return e.message ?? 'Could not reach your TinyWeb box';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TinyWeb')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.bannerMessage != null) ...[
            Card(
              color: Colors.amber.shade100,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(widget.bannerMessage!),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            'Connect to your family box',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: TinyWebColors.text,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: widget.qrScannerBuilder(onDetect: _applyScan),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _serverController,
            decoration: const InputDecoration(
              labelText: 'Family server',
              hintText: 'family.example',
            ),
            textInputAction: TextInputAction.next,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          SegmentedButton<_EnrollMode>(
            segments: const [
              ButtonSegment(value: _EnrollMode.code, label: Text('Code')),
              ButtonSegment(value: _EnrollMode.password, label: Text('Password')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 12),
          if (_mode == _EnrollMode.code)
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'Enroll code'),
              autocorrect: false,
            )
          else ...[
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username'),
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Enroll this device'),
          ),
        ],
      ),
    );
  }
}

enum _EnrollMode { code, password }
