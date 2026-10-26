import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/chat/chat_list_screen.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/room_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

AppSession _session({
  required String role,
  String username = 'alice',
  String mxid = '@alice:family.example',
  List<ChatContact> chatContacts = const [],
}) {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: username,
    role: role,
    mxid: mxid,
    serverName: 'family.example',
    dashboardToken: 'tok',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: FamilyDiscovery(serverOrigin: 'https://family.example'),
    rawJson: {
      'matrix': {
        'status': 'ok',
        'access_token': 't',
        'device_id': 'dev',
        'user_id': mxid,
        'homeserver': 'https://matrix.example',
      },
    },
  );
  session.profile = AppMeProfile(
    username: username,
    role: role,
    mxid: mxid,
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
    chatContacts: chatContacts,
  );
  session.route = AppRoute.home;
  return session;
}

FamilyApiClient _parentApi() {
  return FamilyApiClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/members')) {
        return http.Response(
          jsonEncode([
            {
              'username': 'parent1',
              'role': 'parent',
              'mxid': '@parent1:family.example',
            },
            {
              'username': 'kid1',
              'role': 'kid',
              'mxid': '@kid1:family.example',
            },
            {
              'username': 'kid2',
              'role': 'kid',
              'mxid': '@kid2:family.example',
            },
          ]),
          200,
        );
      }
      return http.Response('not found', 404);
    }),
  );
}

FamilyApiClient _kidApi() {
  return FamilyApiClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/app/contacts')) {
        return http.Response(
          jsonEncode({
            'contacts': [
              {
                'username': 'parent1',
                'mxid': '@parent1:family.example',
                'display_name': 'Mom',
                'role': 'parent',
              },
              {
                'username': 'cousin',
                'mxid': '@cousin:peer.example',
                'display_name': 'cousin',
                'role': 'contact',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }),
  );
}

void main() {
  testWidgets('parent creates group chat with name', (tester) async {
    final chat = FakeChatService();
    final session = _session(
      role: 'parent',
      username: 'parent1',
      mxid: '@parent1:family.example',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(
          session: session,
          chat: chat,
          apiClient: _parentApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('kid1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('kid2'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('group_name_field')),
      'Family Weekend',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start_chat_button')));
    await tester.pumpAndSettle();

    expect(chat.lastCreatedGroupName, 'Family Weekend');
    expect(chat.lastCreatedGroupUserIds, [
      '@kid1:family.example',
      '@kid2:family.example',
    ]);
    final groupRoom = chat.rooms.firstWhere((r) => !r.isDirect);
    expect(groupRoom.title, 'Family Weekend');
    expect(groupRoom.encrypted, isTrue);
    expect(find.byType(RoomScreen), findsOneWidget);
  });

  testWidgets('parent starts direct chat with one member', (tester) async {
    final chat = FakeChatService();
    final session = _session(
      role: 'parent',
      username: 'parent1',
      mxid: '@parent1:family.example',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(
          session: session,
          chat: chat,
          apiClient: _parentApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('kid1'));
    await tester.pumpAndSettle();

    expect(find.text('Start Chat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start_chat_button')));
    await tester.pumpAndSettle();

    expect(chat.lastCreatedGroupUserIds, isNull);
    expect(chat.rooms.first.isDirect, isTrue);
    expect(find.byType(RoomScreen), findsOneWidget);
  });

  testWidgets('kid picks approved contact or manual mxid', (tester) async {
    final chat = FakeChatService();
    final session = _session(
      role: 'kid',
      username: 'kid1',
      mxid: '@kid1:family.example',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(
          session: session,
          chat: chat,
          apiClient: _kidApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Mom'), findsOneWidget);
    expect(find.text('@parent1:family.example'), findsOneWidget);
    expect(find.text('@cousin:peer.example'), findsOneWidget);

    await tester.tap(find.text('Mom'));
    await tester.pumpAndSettle();

    expect(chat.rooms.first.isDirect, isTrue);
    expect(find.byType(RoomScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type Matrix ID...'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '@manual:other.example',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(chat.rooms.first.title, contains('manual'));
    expect(find.byType(RoomScreen), findsOneWidget);
  });
}
