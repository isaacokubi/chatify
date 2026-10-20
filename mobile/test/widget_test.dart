import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:chatify/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('Business API reports HTML responses as a readable API error', () async {
    final api = Api(
      client: MockClient((_) async => http.Response(
            '<!doctype html><html><body>Service unavailable</body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          )),
    );

    await expectLater(
      api.call('GET', '/api/business/organizations'),
      throwsA(isA<ApiException>().having(
        (error) => error.message,
        'message',
        allOf(contains('HTML page instead of JSON'),
            contains('/api/business/organizations')),
      )),
    );
    api.client.close();
  });

  test('authenticated GET falls back to cached data when the network is lost', () async {
    SharedPreferences.setMockInitialValues({});
    final firstClient = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/conversations');
      return http.Response(
        '{"conversations":[{"_id":"conversation-1","lastMessage":{"text":"Previously received"}}]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final firstApi = Api(client: firstClient)..token = 'offline-test-token';
    final online = await firstApi.call('GET', '/api/conversations');
    expect((online['conversations'] as List).single['_id'], 'conversation-1');
    firstClient.close();

    final offlineClient = MockClient((_) async {
      throw http.ClientException('No internet connection');
    });
    final offlineApi = Api(client: offlineClient)..token = 'offline-test-token';
    final cached = await offlineApi.call('GET', '/api/conversations');
    expect((cached['conversations'] as List).single['lastMessage']['text'],
        'Previously received');
    expect(offlineApi.lastResponseFromCache, isTrue);
    expect(offlineApi.offlineDataMode, isTrue);

    final otherAccountClient = MockClient((_) async {
      throw http.ClientException('No internet connection');
    });
    final otherAccountApi = Api(client: otherAccountClient)
      ..token = 'a-different-account-token';
    await expectLater(
      otherAccountApi.call('GET', '/api/conversations'),
      throwsA(isA<http.ClientException>()),
    );
    offlineClient.close();
    otherAccountClient.close();
  });

  test('conversation snapshots are securely cached per account', () async {
    SharedPreferences.setMockInitialValues({});
    final first = Api()..token = 'snapshot-account-one';
    await first.writeConversationSnapshot('conversation-1', [
      {'_id': 'message-1', 'text': 'Saved encrypted history'}
    ]);
    expect(
      (await first.readConversationSnapshot('conversation-1'))!.single['_id'],
      'message-1',
    );

    final otherAccount = Api()..token = 'snapshot-account-two';
    expect(
      await otherAccount.readConversationSnapshot('conversation-1'),
      isNull,
    );
    first.client.close();
    otherAccount.client.close();
  });

  test('temporary API failure preserves the token and still opens sign-in', () async {
    SharedPreferences.setMockInitialValues({'token': 'existing-token'});
    final client = MockClient(
        (_) async => http.Response('{"error":"Temporarily unavailable"}', 503));
    final app = AppState(api: Api(client: client), autoInit: false);
    await app.init();
    expect(app.api.token, 'existing-token');
    expect(app.user, isNull);
    expect(app.ready, isTrue);
    expect(app.restoreError, isNull);
    client.close();
    app.dispose();
  });

  test('saved account opens from local cache when the API is offline', () async {
    SharedPreferences.setMockInitialValues({});
    final setupApi = Api();
    await setupApi.saveToken('offline-account-token');
    await setupApi.writeCachedUser({
      'id': 'user-1',
      'name': 'Offline User',
      'email': 'offline@example.test',
    });
    final client = MockClient((_) async {
      throw http.ClientException('No internet connection');
    });
    final app = AppState(api: Api(client: client), autoInit: false);
    // Use the same mocked secure store and token scope as the previous API.
    await app.init();
    expect(app.ready, isTrue);
    expect(app.user?['name'], 'Offline User');
    expect(app.restoreError, isNull);
    client.close();
    setupApi.client.close();
    app.dispose();
  });

  test('Kenyan M-Pesa numbers normalize before an STK request', () {
    expect(normalizeKenyanPhone('0712 345 678'), '254712345678');
    expect(normalizeKenyanPhone('+254 112 345 678'), '254112345678');
    expect(normalizeKenyanPhone('12345'), isNull);
  });

  test('message load merges socket arrivals without duplicate IDs', () {
    final socketMessage = {
      '_id': 'two',
      'text': 'socket arrival',
      'createdAt': '2026-10-03T10:00:00.000Z',
    };
    final merged = mergeMessages([
      socketMessage
    ], [
      {
        '_id': 'one',
        'text': 'earlier message',
        'createdAt': '2026-10-03T09:59:00.000Z',
      },
      {
        '_id': 'two',
        'text': 'fetched copy',
        'createdAt': '2026-10-03T10:00:00.000Z',
      },
    ]);
    expect(merged.map((message) => message['_id']), ['one', 'two']);
    expect(merged.last['text'], 'fetched copy');
  });

  test(
      'payment socket updates replace the matching card instead of duplicating it',
      () {
    final original = {'paymentId': 'pay-1', 'status': 'PENDING'};
    final updated =
        mergePayment([original], {'paymentId': 'pay-1', 'status': 'SUCCESS'});
    expect(updated, hasLength(1));
    expect(updated.single['status'], 'SUCCESS');
    expect(mergePayment(updated, {'paymentId': 'pay-2', 'status': 'PENDING'}),
        hasLength(2));
  });

  testWidgets('Chatify opens directly on the sign-in screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
          create: (_) => AppState(), child: const ChatifyApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chatify'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Your people. Your conversations.'), findsNothing);
    expect(find.text('Create a new account'), findsOneWidget);
  });

  testWidgets('admin control center exposes overview, people, payments and health',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/status') {
        return http.Response(
          '{"status":"operational","notice":"Observed service status.","components":[{"name":"Database","status":"operational"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/admin/overview') {
        return http.Response(
          '{"stats":{"totalUsers":12,"activeUsers":10,"verifiedUsers":9,"totalBusinesses":3,"businessCustomers":20,"catalogItems":8,"totalConversations":14,"totalMessages":50,"totalMemories":6,"openCases":2,"pendingPayments":1,"failedPayments":0,"successfulPaymentAmount":1200,"newUsers24h":2,"newMessages24h":7,"newBusinesses24h":1},"recentUsers":[],"recentPayments":[]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/admin/users') {
        return http.Response(
          '{"users":[{"_id":"u-1","name":"Amina","email":"amina@example.test","role":"user","status":"active","emailVerified":true}],"total":1}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/admin/payments') {
        return http.Response(
          '{"payments":[{"paymentId":"pay-1","amount":1200,"status":"PENDING","provider":"mock","description":"Order payment"}],"total":1}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"error":"Unexpected request"}', 404);
    });
    final state = AppState(api: Api(client: client), autoInit: false)
      ..api.token = 'admin-session'
      ..user = {'id': 'admin-1', 'role': 'admin'};
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(
        home: Scaffold(body: AdminDashboard()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Chatify Control Center'), findsOneWidget);
    expect(find.text('Service health'), findsOneWidget);
    expect(find.text('Businesses'), findsOneWidget);
    await tester.tap(find.text('People').first);
    await tester.pumpAndSettle();
    expect(find.text('People and access'), findsOneWidget);
    expect(find.text('Amina'), findsOneWidget);
    await tester.tap(find.text('Payments').first);
    await tester.pumpAndSettle();
    expect(find.text('Payment operations'), findsOneWidget);
    expect(find.text('Order payment'), findsOneWidget);
    client.close();
    state.dispose();
  });

  testWidgets('Registration form exposes editable identity and password fields',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
          create: (_) => AppState(), child: const ChatifyApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a new account'));
    await tester.pumpAndSettle();
    expect(find.text('Full name'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Full name'), 'Alice');
    await tester.enterText(
        find.widgetWithText(TextField, 'Email address'), 'alice@example.test');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'password123');
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Full name'))
            .controller!
            .text,
        'Alice');
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Email address'))
            .controller!
            .text,
        'alice@example.test');
  });

  test('device-token DELETE sends the token in its JSON request body',
      () async {
    SharedPreferences.setMockInitialValues({});
    String? requestBody;
    final client = MockClient((request) async {
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/devices');
      requestBody = request.body;
      return http.Response('', 204);
    });
    final api = Api(client: client)..token = 'test-auth-token';
    await api.call('DELETE', '/api/devices', {'token': 'fcm-token'});
    expect(requestBody, '{"token":"fcm-token"}');
    client.close();
  });

  testWidgets('payment card shows amount, state, mock label and payer action',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PaymentCard(
      payment: {
        'paymentId': 'demo-id',
        'payerId': 'payer',
        'amount': 250,
        'description': 'Shared lunch',
        'recipientPhone': '254712345678',
        'status': 'PENDING',
        'provider': 'mock'
      },
      currentUserId: 'payer',
      onRefresh: () {},
      onPay: () => tapped = true,
    ))));
    expect(find.text('Shared lunch'), findsOneWidget);
    expect(find.text('KSh 250 · PENDING · To 254712345678 · Local demo'),
        findsOneWidget);
    await tester.tap(find.text('Pay with M-Pesa'));
    expect(tapped, isTrue);
  });

  test('pending outgoing messages persist, deduplicate and remain account scoped', () async {
    SharedPreferences.setMockInitialValues({});
    final first = Api()..token = 'queue-account-one';
    final queued = <String, dynamic>{
      'conversationId': 'conversation-1',
      'body': {
        'clientMessageId': 'stable-client-id',
        'encryptedPayload': 'ciphertext-only',
        'encryptionVersion': 1,
      },
      'localMessage': {'_id': 'local-stable-client-id'},
      'queuedAt': '2026-10-20T00:00:00Z',
    };
    await first.enqueuePendingMessage(queued);
    await first.enqueuePendingMessage(queued);
    expect((await first.readPendingMessages()).length, 1);
    expect(
      (await first.readPendingMessages()).single['body']['encryptedPayload'],
      'ciphertext-only',
    );

    final other = Api()..token = 'queue-account-two';
    expect(await other.readPendingMessages(), isEmpty);
    await first.removePendingMessage('stable-client-id');
    expect(await first.readPendingMessages(), isEmpty);
    first.client.close();
    other.client.close();
  });

  test('message merge replaces a queued local message with its server copy', () {
    final merged = mergeMessages([
      {
        '_id': 'local-stable-id',
        'clientMessageId': 'stable-id',
        'deliveryStatus': 'pending',
        'text': 'hello',
      }
    ], [
      {
        '_id': 'server-message-id',
        'clientMessageId': 'stable-id',
        'deliveryStatus': 'sent',
        'text': 'hello',
      }
    ]);
    expect(merged, hasLength(1));
    expect(merged.single['_id'], 'server-message-id');
    expect(merged.single['deliveryStatus'], 'sent');
  });


  test('payment initiation is never automatically replayed after timeout', () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final api = Api(
      client: MockClient((_) async {
        attempts++;
        throw TimeoutException('payment request timed out');
      }),
    )..token = 'payment-account';
    await expectLater(
      api.call('POST', '/api/payments/payment-1/initiate', {}),
      throwsA(isA<TimeoutException>()),
    );
    expect(attempts, 1);
    api.client.close();
  });

  test('concurrent pending message enqueues do not overwrite each other', () async {
    SharedPreferences.setMockInitialValues({});
    final api = Api()..token = 'parallel-queue-account';
    await Future.wait(List.generate(8, (index) {
      final id = 'parallel-$index';
      return api.enqueuePendingMessage({
        'conversationId': 'conversation-1',
        'body': {'clientMessageId': id, 'encryptedPayload': 'ciphertext'},
      });
    }));
    final queued = await api.readPendingMessages();
    expect(queued, hasLength(8));
    expect(queued.map((item) => item['clientMessageId']).toSet().length, 8);
    api.client.close();
  });

  test('app-wide outbox sync sends queued messages after leaving the chat', () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final api = Api(
      client: MockClient((request) async {
        attempts++;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/conversations/conversation-1/messages');
        expect(request.headers.keys.any((key) => key.toLowerCase() == 'authorization'), isTrue);
        final body = request.body;
        expect(body, contains('background-client-id'));
        return http.Response(
          '{"message":{"_id":"server-message","clientMessageId":"background-client-id"}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..token = 'background-sync-account';
    await api.enqueuePendingMessage({
      'conversationId': 'conversation-1',
      'clientMessageId': 'background-client-id',
      'body': {
        'clientMessageId': 'background-client-id',
        'encryptedPayload': 'ciphertext',
        'encryptionVersion': 1,
      },
    });

    expect(await api.syncPendingMessages(), 1);
    expect(attempts, 1);
    expect(await api.readPendingMessages(), isEmpty);
    api.client.close();
  });

  test('app-wide outbox keeps a message queued when reconnect sync fails', () async {
    SharedPreferences.setMockInitialValues({});
    final api = Api(
      client: MockClient((_) async {
        throw http.ClientException('airplane mode');
      }),
    )..token = 'background-offline-account';
    await api.enqueuePendingMessage({
      'conversationId': 'conversation-1',
      'clientMessageId': 'offline-client-id',
      'body': {
        'clientMessageId': 'offline-client-id',
        'encryptedPayload': 'ciphertext',
        'encryptionVersion': 1,
      },
    });

    expect(await api.syncPendingMessages(), 0);
    expect((await api.readPendingMessages()).single['clientMessageId'],
        'offline-client-id');
    api.client.close();
  });

}
