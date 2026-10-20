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

  test('authenticated GET falls back to cached data when the network is lost',
      () async {
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

  test('offline mutation storage scope changes with the authenticated account',
      () {
    final first = Api()..token = 'account-one-token';
    final second = Api()..token = 'account-two-token';
    expect(first.accountScope, isNotEmpty);
    expect(second.accountScope, isNot(first.accountScope));
    first.client.close();
    second.client.close();
  });

  test('temporary API failure preserves the stored login token', () async {
    SharedPreferences.setMockInitialValues({'token': 'existing-token'});
    final client = MockClient(
        (_) async => http.Response('{"error":"Temporarily unavailable"}', 503));
    final app = AppState(api: Api(client: client), autoInit: false);
    await app.init();
    expect(app.api.token, 'existing-token');
    expect(app.user, isNull);
    expect(app.restoreError, contains('Temporarily unavailable'));
    client.close();
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

  testWidgets('Chatify opens directly on the sign-in screen', (tester) async {
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

  testWidgets('Business catalogue uses most of a phone viewport',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/business/organizations') {
        return http.Response(
          '{"organizations":[{"_id":"org-1","name":"Demo Shop","slug":"demo-shop"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/dashboard')) {
        return http.Response('{"metrics":{}}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/catalog')) {
        return http.Response('{"items":[{"_id":"item-1","name":"Phone"}]}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/customers')) {
        return http.Response('{"customers":[]}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/documents')) {
        return http.Response('{"documents":[]}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/tasks')) {
        return http.Response('{"tasks":[]}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"error":"Unexpected request"}', 404,
          headers: {'content-type': 'application/json'});
    });
    final state = AppState(api: Api(client: client), autoInit: false)
      ..api.token = 'business-layout-account'
      ..user = {'id': 'business-owner'};
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(390, 844)),
          child: Scaffold(body: BusinessHub()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(tester.getSize(find.byType(TabBarView)).height, greaterThan(422));
    await tester.binding.setSurfaceSize(null);
    client.close();
    state.dispose();
  });

  testWidgets('profile picture keeps its full frame and opens an enlarged view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((_) async => http.Response('', 404));
    final state = AppState(api: Api(client: client), autoInit: false)
      ..user = {
        'id': 'profile-owner',
        'name': 'Profile Owner',
        'profileImage': 'https://images.example/profile.jpg',
      };
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: Profile())),
    ));
    await tester.pump();

    final preview = find.byKey(const ValueKey('profile-picture-preview'));
    expect(tester.getSize(preview), const Size(180, 220));
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Close enlarged profile picture'), findsOneWidget);

    await tester.tap(find.byTooltip('Close enlarged profile picture'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    client.close();
    state.dispose();
  });

  testWidgets(
      'school fee form prefills editable parent phone and configured options',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/schools') {
        return http.Response(
          '{"schools":[{"id":"school-1","name":"Demo School","role":"parent","paymentProfile":{"method":"mpesa_till","tillNumber":"123456"}}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/schools/verification-requests') {
        return http.Response('{"reviewer":false,"requests":[]}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/messages')) {
        return http.Response('{"messages":[],"total":0}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/members')) {
        return http.Response('{"members":[],"total":0}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/fees')) {
        return http.Response(
          '{"payments":[],"total":0,"paymentOptions":{"schoolName":"Demo School","configured":true,"method":"mpesa_till","tillNumber":"123456","officialPhone":"0712345678","darajaConfigured":true}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/students')) {
        return http.Response(
          '{"students":[{"fullName":"Amina Parent","className":"4"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"error":"Unexpected request"}', 404,
          headers: {'content-type': 'application/json'});
    });
    final state = AppState(api: Api(client: client), autoInit: false)
      ..api.token = 'school-parent-token'
      ..user = {
        'id': 'parent-1',
        'phone': '0711222333',
      };
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: SchoolWorkspacePage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fees'));
    await tester.pumpAndSettle();

    final phoneField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText ==
            'Your M-Pesa phone receiving the STK prompt');
    expect(phoneField, findsOneWidget);
    expect(tester.widget<TextField>(phoneField).controller?.text, '0711222333');
    await tester.enterText(phoneField, '0700111222');
    expect(tester.widget<TextField>(phoneField).controller?.text, '0700111222');

    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Send Money (0712345678)'), findsWidgets);
    await tester.tap(find.text('Send Money (0712345678)').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('The app will record this as pending'),
        findsOneWidget);

    client.close();
    state.dispose();
  });

  testWidgets(
      'admin control center exposes overview, people, payments and health',
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
}
