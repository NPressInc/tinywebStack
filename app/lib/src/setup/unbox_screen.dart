import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'setup_client.dart';
import 'setup_discovery.dart';
import 'setup_link.dart';
import 'setup_models.dart';

class UnboxScreen extends StatefulWidget {
  const UnboxScreen({
    super.key,
    required this.session,
    this.initialCode,
    this.initialError,
    this.locator,
    this.client,
    this.pollInterval = const Duration(seconds: 2),
  });

  final AppSession session;
  final String? initialCode;
  final String? initialError;
  final SetupLocator? locator;
  final SetupClient? client;
  final Duration pollInterval;

  @override
  State<UnboxScreen> createState() => _UnboxScreenState();
}

class _UnboxScreenState extends State<UnboxScreen> {
  final _codeController = TextEditingController();
  final _familyController = TextEditingController();
  final _parentController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _searching = false;
  DiscoveredBox? _box;
  SetupStatus? _status;
  String? _error;
  bool _busy = false;
  bool _signingIn = false;
  Timer? _poll;
  SetupClient? _ownedClient;

  SetupLocator get _locator => widget.locator ?? defaultSetupLocator();

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCode;
    if (initial != null && initial.isNotEmpty) {
      _codeController.text = initial;
    }
    _error = widget.initialError;
    if (widget.client == null) {
      _search();
    }
  }

  @override
  void didUpdateWidget(UnboxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initialCode;
    if (next != null && next.isNotEmpty && next != oldWidget.initialCode) {
      _codeController.text = next;
    }
    if (widget.initialError != null && widget.initialError != oldWidget.initialError) {
      _error = widget.initialError;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _codeController.dispose();
    _familyController.dispose();
    _parentController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = _error;
    });
    final box = await _locator.find();
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = false;
      _box = box;
    });
  }

  SetupClient _client() {
    final injected = widget.client;
    if (injected != null) {
      return injected;
    }
    final existing = _ownedClient;
    if (existing != null) {
      return existing;
    }
    final box = _box;
    if (box == null) {
      throw SetupException(
        "Can't see a TinyWeb on this Wi-Fi yet. Plug in power and ethernet, then try again.",
      );
    }
    final created = SetupClient.forBox(box);
    _ownedClient = created;
    return created;
  }

  Future<void> _submit() async {
    final parsed = parseSetupCode(_codeController.text);
    if (!parsed.isOk) {
      setState(() => _error = parsed.error);
      return;
    }
    if (_familyController.text.trim().isEmpty) {
      setState(() => _error = 'Enter a family name, such as Floyd.');
      return;
    }
    if (_parentController.text.trim().isEmpty) {
      setState(() => _error = 'Enter your name.');
      return;
    }
    if (_passwordController.text.length < 8) {
      setState(() => _error = 'Use at least 8 characters for the password.');
      return;
    }
    if (_passwordController.text != _confirmController.text) {
      setState(() => _error = 'Those passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await _client().submit(
        code: parsed.code!,
        familyName: _familyController.text.trim(),
        parentName: _parentController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      _show(status);
    } on SetupException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _show(SetupStatus status) {
    setState(() {
      _status = status;
      _error = status.error;
    });
    if (status.phase == 'ready') {
      _signIn(status);
      return;
    }
    if (status.phase == 'installing' || status.phase == 'blocked') {
      _poll ??= Timer.periodic(widget.pollInterval, (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    try {
      final status = await _client().fetchStatus();
      if (!mounted) {
        return;
      }
      _show(status);
    } on SetupException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message);
    }
  }

  Future<void> _signIn(SetupStatus status) async {
    if (_signingIn) {
      return;
    }
    final origin = status.enrollOrigin;
    final username = status.parentUsername;
    if (origin == null || username == null || username.isEmpty) {
      setState(() => _error = 'TinyWeb is not ready to sign in yet.');
      return;
    }
    _signingIn = true;
    _poll?.cancel();
    try {
      final discovery = await widget.session.discoverServer(origin);
      final bundle = await widget.session.enrollWithPassword(
        discovery: discovery,
        username: username,
        password: _passwordController.text,
      );
      await widget.session.completeEnrollment(
        bundle,
        enrollPassword: _passwordController.text,
      );
      _passwordController.clear();
      _confirmController.clear();
    } on EnrollException catch (e) {
      _signingIn = false;
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message ?? 'Could not sign in yet.');
    } catch (_) {
      _signingIn = false;
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Could not sign in yet.');
    }
  }

  void _tryAgain() {
    _poll?.cancel();
    _poll = null;
    _signingIn = false;
    setState(() {
      _status = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('TinyWeb')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            status == null ? 'Set up your TinyWeb' : 'Setting up ${status.domain ?? 'your family'}',
            key: const Key('unbox-title'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: TinyWebColors.text,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            status == null
                ? 'Plug in power and ethernet. This phone should be on the same Wi-Fi.'
                : 'This stays here while TinyWeb finishes. You do not need a router page or a terminal.',
          ),
          const SizedBox(height: 16),
          if (status == null) ..._form(context) else ..._progress(context, status),
        ],
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final found = widget.client != null || _box != null;
    return [
      if (_searching)
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Looking for a TinyWeb on this Wi-Fi.'),
        )
      else if (!found)
        Card(
          child: ListTile(
            title: const Text('No TinyWeb on this Wi-Fi yet.'),
            subtitle: const Text('Plug in power and ethernet, then stay on this Wi-Fi.'),
            trailing: TextButton(
              onPressed: _search,
              child: const Text('Try again'),
            ),
          ),
        ),
      if (found && !_searching)
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.check_circle, color: TinyWebColors.blueDeep),
          title: Text('Found a TinyWeb.'),
        ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('unbox-setup-code'),
        controller: _codeController,
        decoration: const InputDecoration(
          labelText: 'Setup code',
          helperText: 'From the card in the box, or the sticker on the bottom.',
        ),
        autocorrect: false,
        enableSuggestions: false,
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('unbox-family-name'),
        controller: _familyController,
        decoration: const InputDecoration(
          labelText: 'Family name',
          hintText: 'Floyd',
        ),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('unbox-parent-name'),
        controller: _parentController,
        decoration: const InputDecoration(
          labelText: 'Your name',
          hintText: 'William',
        ),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('unbox-password'),
        controller: _passwordController,
        decoration: const InputDecoration(labelText: 'Password'),
        obscureText: true,
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('unbox-password-confirm'),
        controller: _confirmController,
        decoration: const InputDecoration(labelText: 'Confirm password'),
        obscureText: true,
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 20),
      FilledButton(
        key: const Key('unbox-submit'),
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Create family'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => widget.session.openExistingFamilyEnroll(),
        child: const Text('Join a family that is already set up'),
      ),
    ];
  }

  List<Widget> _progress(BuildContext context, SetupStatus status) {
    return [
      for (final step in status.steps)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _stepIcon(step.state),
          title: Text(step.label),
          subtitle: step.detail.isEmpty ? null : Text(step.detail),
        ),
      if (_signingIn) ...[
        const SizedBox(height: 12),
        const Text('Signing you in.'),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      if (status.phase == 'failed' || status.phase == 'blocked') ...[
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _tryAgain,
          child: const Text('Try again'),
        ),
      ],
    ];
  }

  Widget _stepIcon(String state) {
    switch (state) {
      case 'done':
        return const Icon(Icons.check_circle, color: TinyWebColors.blueDeep);
      case 'current':
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case 'blocked':
        return const Icon(Icons.hourglass_empty, color: TinyWebColors.textMuted);
      case 'failed':
        return Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error);
      default:
        return const Icon(Icons.circle_outlined, color: TinyWebColors.textMuted);
    }
  }
}
