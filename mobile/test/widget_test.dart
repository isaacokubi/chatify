import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:chatify/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('temporary API failure preserves the stored login token', () async {
    SharedPreferences.setMockInitialValues({'token': 'existing-token'});
    final client = MockClient((_) async =>
        http.Response('{"error":"Temporarily unavailable"}', 503));
    final app = AppState(api: Api(client: client), autoInit: false);
    await app.init();
    expect(app.api.token, 'existing-token');
    expect(app.user, isNull);
    expect(app.restoreError, contains('Temporarily unavailable'));
    client.close();
    app.dispose();
  });

  test('message load merges socket arrivals without duplicate IDs', () {
    final socketMessage = {
      '_id': 'two',
      'text': 'socket arrival',
      'createdAt': '2026-10-03T10:00:00.000Z',
    };
    final merged = mergeMessages([socketMessage], [
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

  testWidgets('Chatify renders branded authentication screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
          create: (_) => AppState(), child: const ChatifyApp()),
    );
    await tester.pump();
    expect(find.text('Chatify'), findsOneWidget);
    expect(find.text('Chat. Remember. Let Go.'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
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
}
