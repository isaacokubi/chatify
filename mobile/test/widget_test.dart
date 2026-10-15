import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:chatify/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
