import 'package:flutter/material.dart';
import 'package:tw_matrix_spike/src/rust/api/matrix.dart';
import 'package:tw_matrix_spike/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MatrixSpikeApp());
}

class MatrixSpikeApp extends StatefulWidget {
  const MatrixSpikeApp({super.key});

  @override
  State<MatrixSpikeApp> createState() => _MatrixSpikeAppState();
}

class _MatrixSpikeAppState extends State<MatrixSpikeApp> {
  List<RoomSummary> _rooms = const [];
  String _status = 'Not logged in';

  Future<void> _loginDemo() async {
    setState(() => _status = 'Logging in…');
    try {
      final session = await login(
        homeserverUrl: 'https://family-b.family.test',
        username: 'bob',
        password: '***',
        storeDir: '/tmp/tw_matrix_spike_ui',
        caCertPem: null,
        deviceName: 'tw_matrix_spike_ui',
      );
      final rooms = await session.listRooms();
      final userId = await session.userId();
      setState(() {
        _rooms = rooms;
        _status = 'Logged in as $userId (${rooms.length} rooms)';
      });
    } catch (e) {
      setState(() => _status = 'Login failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('tw_matrix_spike')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_status),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loginDemo,
                child: const Text('Login & list rooms (demo)'),
              ),
              const SizedBox(height: 16),
              Text('Rooms (${_rooms.length})'),
              Expanded(
                child: ListView.builder(
                  itemCount: _rooms.length,
                  itemBuilder: (context, index) {
                    final r = _rooms[index];
                    return ListTile(
                      title: Text(r.name),
                      subtitle: Text(
                        '${r.roomId} · members=${r.joinedMembers} · e2ee=${r.isEncrypted}',
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
