import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:chatify/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
