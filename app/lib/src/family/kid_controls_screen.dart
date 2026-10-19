import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'kid_detail_screen.dart';

class KidControlsScreen extends StatefulWidget {
  const KidControlsScreen({
    super.key,
    required this.session,
    this.api,
  });

  final AppSession session;
  final FamilyApiClient? api;

  @override
  State<KidControlsScreen> createState() => _KidControlsScreenState();
}

class _KidControlsScreenState extends State<KidControlsScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  List<FamilyMember> _kids = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final members = await _api.fetchMembers(bundle);
      setState(() {
        _kids = members.where((m) => m.role == 'kid').toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _refresh, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (_kids.isEmpty) {
      return const Center(child: Text('No child accounts on this family box.'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _kids.length,
        itemBuilder: (context, index) {
          final kid = _kids[index];
          final label = kid.displayName?.isNotEmpty == true
              ? kid.displayName!
              : kid.username;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.child_care, color: TinyWebColors.blueDeep),
              title: Text(label),
              subtitle: Text(kid.mxid.isNotEmpty ? kid.mxid : kid.username),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => KidDetailScreen(
                      session: widget.session,
                      kid: kid,
                      api: widget.api,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
