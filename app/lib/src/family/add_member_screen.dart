import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import 'one_time_secret_panel.dart';

class AddMemberScreen extends StatefulWidget {
  const AddMemberScreen({
    super.key,
    required this.session,
    this.api,
  });

  final AppSession session;
  final FamilyApiClient? api;

  @override
  State<AddMemberScreen> createState() => _AddMemberScreenState();
}

class _AddMemberScreenState extends State<AddMemberScreen> {
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  String _role = 'kid';
  bool _submitting = false;
  String? _error;
  MemberCreateResult? _created;

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    final username = _usernameController.text.trim().toLowerCase();
    if (username.isEmpty) {
      setState(() => _error = 'Username is required');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await _api.createMember(
        bundle,
        username: username,
        role: _role,
        displayName: _displayNameController.text.trim(),
        issueEnrollCode: true,
      );
      setState(() {
        _created = result;
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_created != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Member added')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${_created!.username} was added as ${_created!.role}.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            OneTimeSecretPanel(
              title: 'Sign-in password',
              secret: _created!.password,
              hint: 'Share this password securely. It will not be shown again.',
              qrPayload: _created!.enrollQrPayload,
              secondaryLabel: _created!.enrollCode != null
                  ? 'Or enter this one-time enroll code'
                  : null,
              secondarySecret: _created!.enrollCode,
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Add family member')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: 'Username',
              hintText: 'lowercase letters and numbers',
            ),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _displayNameController,
            decoration: const InputDecoration(
              labelText: 'Display name (optional)',
            ),
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 12),
          const Text('Role'),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'kid', label: Text('Child')),
              ButtonSegment(value: 'parent', label: Text('Parent')),
            ],
            selected: {_role},
            onSelectionChanged: _submitting
                ? null
                : (s) => setState(() => _role = s.first),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create account'),
          ),
        ],
      ),
    );
  }
}
