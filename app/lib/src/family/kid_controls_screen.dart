import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'accept_link_invite_screen.dart';
import 'add_member_screen.dart';
import 'member_detail_screen.dart';
import 'one_time_secret_panel.dart';

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
  List<FamilyMember> _members = [];
  List<FamilyInviteRow> _invites = [];
  List<LinkedFamily> _linkedFamilies = [];
  bool _loading = true;
  String? _error;
  HouseholdInviteCreateResult? _newInvite;

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
      final results = await Future.wait([
        _api.fetchMembers(bundle),
        _api.fetchInvites(bundle),
        _api.fetchLinkedFamilies(bundle),
      ]);
      final members = results[0] as List<FamilyMember>;
      members.sort((a, b) {
        if (a.role != b.role) {
          return a.role == 'parent' ? -1 : 1;
        }
        return a.username.compareTo(b.username);
      });
      setState(() {
        _members = members;
        _invites = results[1] as List<FamilyInviteRow>;
        _linkedFamilies = results[2] as List<LinkedFamily>;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openMember(FamilyMember member) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => MemberDetailScreen(
          session: widget.session,
          member: member,
          api: widget.api,
        ),
      ),
    );
    if (changed == true) {
      await _refresh();
    }
  }

  Future<void> _addMember() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AddMemberScreen(
          session: widget.session,
          api: widget.api,
        ),
      ),
    );
    if (added == true) {
      await _refresh();
    }
  }

  Future<void> _acceptInvite() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AcceptLinkInviteScreen(
          session: widget.session,
          api: widget.api,
        ),
      ),
    );
    if (linked == true) {
      await _refresh();
    }
  }

  Future<void> _createInvite() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final invite = await _api.createHouseholdInvite(bundle);
      setState(() {
        _newInvite = invite;
        _loading = false;
      });
      await _refresh();
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _deleteInvite(FamilyInviteRow invite) async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete invite?'),
        content: const Text('Pending household links stop working immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      await _api.deleteHouseholdInvite(bundle, invite.nonce);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Family'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Members'),
              Tab(text: 'Invites'),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
        ),
        floatingActionButton: Builder(
          builder: (context) {
            final tab = DefaultTabController.of(context);
            return AnimatedBuilder(
              animation: tab,
              builder: (context, _) {
                if (tab.index == 0) {
                  return FloatingActionButton.extended(
                    onPressed: _loading ? null : _addMember,
                    icon: const Icon(Icons.person_add),
                    label: const Text('Add'),
                  );
                }
                return FloatingActionButton.extended(
                  onPressed: _loading ? null : _createInvite,
                  icon: const Icon(Icons.link),
                  label: const Text('New invite'),
                );
              },
            );
          },
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _members.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _members.isEmpty) {
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

    return TabBarView(
      children: [
        RefreshIndicator(
          onRefresh: _refresh,
          child: _membersTab(),
        ),
        RefreshIndicator(
          onRefresh: _refresh,
          child: _invitesTab(),
        ),
      ],
    );
  }

  Widget _membersTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        _linkedFamiliesSection(),
        if (_members.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: Text('No family members yet.')),
          )
        else
          ..._members.map((member) {
            final devices = member.deviceCount == 1
                ? '1 phone'
                : '${member.deviceCount} phones';
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: Icon(
                  member.role == 'parent'
                      ? Icons.supervisor_account
                      : Icons.child_care,
                  color: TinyWebColors.blueDeep,
                ),
                title: Text(member.displayLabel),
                subtitle: Text(
                  '${member.role == 'parent' ? 'Parent' : 'Child'} · $devices',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openMember(member),
              ),
            );
          }),
      ],
    );
  }

  Widget _linkedFamiliesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Linked families',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _acceptInvite,
              icon: const Icon(Icons.link),
              label: const Text('Accept invite'),
            ),
          ],
        ),
        if (_linkedFamilies.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('No linked households yet.'),
          )
        else
          ..._linkedFamilies.map(
            (f) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.home_work_outlined),
                title: Text(f.familyName),
                subtitle: Text(f.domain),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _invitesTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        if (_newInvite != null)
          OneTimeSecretPanel(
            title: 'New household invite',
            secret: _newInvite!.token,
            hint: 'Share this link with another family. Shown once.',
            qrPayload: _newInvite!.inviteUrl,
            secondaryLabel: 'Invite link',
            secondarySecret: _newInvite!.inviteUrl,
          ),
        if (_invites.isEmpty && _newInvite == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Text('No pending household invites.'),
            ),
          )
        else
          ..._invites.map(
            (inv) => Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: const Icon(Icons.link),
                title: Text('Invite ${inv.nonce}'),
                subtitle: Text(
                  [
                    if (inv.issuer != null) 'from ${inv.issuer}',
                    if (inv.createdBy != null) 'by ${inv.createdBy}',
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _deleteInvite(inv),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
