import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

const int kSetupBeaconPort = 4735;
const String kSetupServiceType = '_tinyweb-setup._tcp';

class DiscoveredBox {
  const DiscoveredBox({
    required this.ip,
    required this.port,
    this.hostLabel = 'tinyweb.local',
  });

  final String ip;
  final int port;
  final String hostLabel;
}

abstract class SetupLocator {
  Future<DiscoveredBox?> find({Duration timeout = const Duration(seconds: 8)});
}

class FakeSetupLocator implements SetupLocator {
  FakeSetupLocator(this.box);

  final DiscoveredBox? box;

  @override
  Future<DiscoveredBox?> find({Duration timeout = const Duration(seconds: 8)}) async {
    return box;
  }
}

SetupLocator defaultSetupLocator() {
  return CompositeSetupLocator([
    BonsoirSetupLocator(),
    SocketSetupLocator(),
  ]);
}

class CompositeSetupLocator implements SetupLocator {
  CompositeSetupLocator(this.locators);

  final List<SetupLocator> locators;

  @override
  Future<DiscoveredBox?> find({Duration timeout = const Duration(seconds: 8)}) async {
    final results = await Future.wait(
      locators.map((locator) async {
        try {
          return await locator.find(timeout: timeout);
        } catch (_) {
          return null;
        }
      }),
    );
    for (final box in results) {
      if (box != null) {
        return box;
      }
    }
    return null;
  }
}

class BonsoirSetupLocator implements SetupLocator {
  @override
  Future<DiscoveredBox?> find({Duration timeout = const Duration(seconds: 8)}) async {
    final discovery = BonsoirDiscovery(type: kSetupServiceType, printLogs: false);
    await discovery.initialize();
    final found = Completer<DiscoveredBox?>();
    final sub = discovery.eventStream?.listen((event) {
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        unawaited(event.service.resolve(discovery.serviceResolver));
      } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
        final ip = event.service.hostAddress;
        final port = event.service.port;
        if (ip != null && ip.isNotEmpty && isLocalSetupPeer(ip) && !found.isCompleted) {
          found.complete(DiscoveredBox(ip: ip, port: port));
        }
      }
    });
    await discovery.start();
    try {
      return await found.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub?.cancel();
      await discovery.stop();
    }
  }
}

class SocketSetupLocator implements SetupLocator {
  @override
  Future<DiscoveredBox?> find({Duration timeout = const Duration(seconds: 8)}) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kSetupBeaconPort,
        reuseAddress: true,
      );
    } on SocketException {
      return null;
    }
    final found = Completer<DiscoveredBox?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read || found.isCompleted) {
        return;
      }
      final datagram = socket!.receive();
      if (datagram == null) {
        return;
      }
      final box = discoveredBoxFromBeacon(datagram.data, datagram.address.address);
      if (box != null) {
        found.complete(box);
      }
    });
    try {
      return await found.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
      socket.close();
    }
  }
}

bool isLocalSetupPeer(String ip) {
  final addr = InternetAddress.tryParse(ip);
  if (addr == null || addr.type != InternetAddressType.IPv4) {
    return false;
  }
  final b = addr.rawAddress;
  if (b[0] == 10 || b[0] == 127) {
    return true;
  }
  if (b[0] == 192 && b[1] == 168) {
    return true;
  }
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) {
    return true;
  }
  if (b[0] == 169 && b[1] == 254) {
    return true;
  }
  return false;
}

DiscoveredBox? discoveredBoxFromBeacon(List<int> data, String sourceIp) {
  if (!isLocalSetupPeer(sourceIp)) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map) {
      return null;
    }
    if (decoded['service'] != 'tinyweb-setup' || decoded['v'] != 1) {
      return null;
    }
    final port = decoded['port'];
    if (port is! int || port <= 0 || port > 65535) {
      return null;
    }
    return DiscoveredBox(ip: sourceIp, port: port);
  } catch (_) {
    return null;
  }
}
