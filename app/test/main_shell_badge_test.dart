import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/shell/main_shell.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _parentSession() {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'parent1',
    role: 'parent',
    mxid: '@parent1:family.example',
    serverName: 'family.example',
    dashboardToken: 'parent-token',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
  );
  session.profile = AppMeProfile(
    username: 'parent1',
    role: 'parent',
    mxid: '@parent1:family.example',
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

FamilyApiClient _locationsApi() {
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/map')) {
      return http.Response(
        '{"available":false,"attribution":"x","maxzoom":14,"flavor":"light","tiles_url":"https://family.example/family/tiles/basemap.pmtiles","glyphs_url":"https://family.example/family/tiles/fonts/x","sprites_url":"https://family.example/family/tiles/sprites/v4/light","style_url":"https://family.example/family/tiles/style.json"}',
        200,
      );
    }
    if (request.url.path.endsWith('/locations')) {
      return http.Response('{"kids":[]}', 200);
    }
    return http.Response('{}', 404);
  });
  return FamilyApiClient(client: client);
}

Widget _shell(FakeChatService chat) {
  return MaterialApp(
    home: MainShell(
      session: _parentSession(),
      chatService: chat,
      locationsApi: _locationsApi(),
    ),
  );
}

Finder _navBarBadgeLabels() {
  return find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Badge &&
          widget.isLabelVisible &&
          widget.label is Text &&
          (widget.label! as Text).data != null &&
          (widget.label! as Text).data!.isNotEmpty,
    ),
  );
}

void main() {
  testWidgets('Chat tab shows no badge when total unread is zero', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(roomId: '!a', title: 'A', unread: 0),
        ChatRoom(roomId: '!b', title: 'B', unread: 0),
      ],
    );

    await tester.pumpWidget(_shell(chat));
    await tester.pumpAndSettle();

    expect(_navBarBadgeLabels(), findsNothing);
  });

  testWidgets('Chat tab badge shows total unread across rooms', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(roomId: '!a', title: 'A', unread: 2),
        ChatRoom(roomId: '!b', title: 'B', unread: 3),
      ],
    );

    await tester.pumpWidget(_shell(chat));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('5'),
      ),
      findsWidgets,
    );
    expect(_navBarBadgeLabels(), findsWidgets);
  });

  testWidgets('Chat tab badge updates when roomsListenable changes', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(roomId: '!a', title: 'A', unread: 0),
      ],
    );

    await tester.pumpWidget(_shell(chat));
    await tester.pumpAndSettle();
    expect(_navBarBadgeLabels(), findsNothing);

    final rooms = chat.roomsListenable as ValueNotifier<List<ChatRoom>>;
    rooms.value = [
      ChatRoom(roomId: '!a', title: 'A', unread: 2),
      ChatRoom(roomId: '!b', title: 'B', unread: 3),
    ];
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('5'),
      ),
      findsWidgets,
    );
    expect(_navBarBadgeLabels(), findsWidgets);
  });
}
