import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
    this.initialLink,
    this.qrScannerBuilder = defaultEnrollQrScanner,
  });

  final AppSession session;
  final String? bannerMessage;

  /// `tinyweb://` or `https://<family>/family/join#code=...` from the OS.
  /// When the phone cannot deliver a link, the fields below are the fallback.
  final String? initialLink;
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
  String? _linkedOrigin;
  String? _lastAutoLink;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLink;
    if (initial != null && initial.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _applyIncomingLink(initial, autoSubmit: true);
        }
      });
    }
  }

  @override
  void didUpdateWidget(EnrollScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initialLink;
    if (next != null &&
        next.trim().isNotEmpty &&
        next != oldWidget.initialLink) {
      _applyIncomingLink(next, autoSubmit: true);
    }
  }

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
      _linkedOrigin = parsed.serverOrigin;
      _serverController.text = parsed.serverHost ?? parsed.serverOrigin!;
    }
    if (parsed.code != null && parsed.code!.isNotEmpty) {
      _codeController.text = parsed.code!;
      _mode = _EnrollMode.code;
    } else if (!raw.contains('://')) {
      _codeController.text = raw;
    }
    setState(() {});
  }

  Future<void> _applyIncomingLink(String raw, {required bool autoSubmit}) async {
    _applyScan(raw);
    if (!autoSubmit || _busy) {
      return;
    }
    final parsed = parseEnrollLink(raw);
    if (parsed.serverOrigin == null ||
        parsed.code == null ||
        parsed.code!.isEmpty) {
      return;
    }
    if (_lastAutoLink == raw) {
      return;
    }
    _lastAutoLink = raw;
    await _submit();
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
          'Enter a family name (e.g. smith) or HTTPS server (e.g. smith.tinyweb.win)',
        );
      }
      final linked = _linkedOrigin;
      if (linked != null && !familyHostsMatch(linked, origin)) {
        throw EnrollException(
          EnrollErrorKind.wrongServer,
          wrongServerMessage(
            askedFor: hostOf(linked),
            reached: hostOf(origin),
          ),
        );
      }

      final discovery = await widget.session.discoverServer(origin);

      final EnrollmentBundle bundle;
      if (_mode == _EnrollMode.code) {
        final code = _codeController.text.trim();
        if (code.isEmpty) {
          throw EnrollException(EnrollErrorKind.invalidCode, 'Enter the one-time code from the parent');
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
    } on TimeoutException {
      setState(() => _error = unreachableBoxMessage(_serverController.text));
    } on SocketException {
      setState(() => _error = unreachableBoxMessage(_serverController.text));
    } on http.ClientException {
      setState(() => _error = unreachableBoxMessage(_serverController.text));
    } on TlsException {
      setState(() => _error = unreachableBoxMessage(_serverController.text));
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
      case EnrollErrorKind.codeExpired:
        return e.message ?? expiredCodeMessage();
      case EnrollErrorKind.codeUsed:
        return e.message ?? usedCodeMessage();
      case EnrollErrorKind.invalidCode:
        return e.message ?? invalidCodeMessage();
      case EnrollErrorKind.wrongServer:
        return e.message ?? 'This phone reached a different family server.';
      case EnrollErrorKind.network:
      case EnrollErrorKind.server:
        return e.message ?? unreachableBoxMessage(_serverController.text);
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
          const SizedBox(height: 8),
          const Text(
            'Scan the code from a parent, or type your family name and the one-time code. '
            'If a link opened this app, those fields are filled in for you.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: widget.qrScannerBuilder(
              onDetect: (raw) {
                _applyIncomingLink(raw, autoSubmit: true);
              },
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _serverController,
            decoration: const InputDecoration(
              labelText: 'Family server',
              hintText: 'smith (or smith.tinyweb.win)',
              helperText:
                  'Enter your family name for <name>.tinyweb.win, or a full domain',
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
              decoration: const InputDecoration(
                labelText: 'Enroll code',
                helperText: 'Works once. Ask a parent for a new one if it has expired.',
              ),
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
          TextButton(
            onPressed: _busy ? null : () => widget.session.openUnbox(),
            child: const Text('Set up a new TinyWeb'),
          ),
          const SizedBox(height: 8),
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
