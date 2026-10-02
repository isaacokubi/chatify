import 'package:flutter_test/flutter_test.dart';
import 'package:chatify/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Chatify renders branded authentication screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(create: (_) => AppState(), child: const ChatifyApp()),
    );
    await tester.pump();
    expect(find.text('Chatify'), findsOneWidget);
    expect(find.text('Chat. Remember. Let Go.'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
