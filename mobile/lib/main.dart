// CHATIFY MOBILE APP — READING GUIDE
// This file contains the Flutter screens and much of the client-side state management.
// Api sends authenticated HTTP requests to the Express server; AppState stores session,
// conversations, contacts, memories, notifications and payment state; the widgets below
// turn that data into the welcome, sign-in, chat, memory, payment and profile screens.
// Real-time chat updates arrive through Socket.IO. Keep server-side authorization and
// payment decisions on the server; a mobile-side check is never a security boundary.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_saver/file_saver.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';

// Represents a readable API failure so screens can show a useful message instead of raw transport errors.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

// Central HTTP client: adds the API base URL and authentication token, sends requests, and parses responses.
class Api {
  final http.Client client;
  Api({http.Client? client}) : client = client ?? http.Client();
  String get base => const String.fromEnvironment('CHATIFY_API',
      defaultValue: 'https://chatify-api-c1eh.onrender.com');
  String? token;
  Future<void> restore() async {
    token = (await SharedPreferences.getInstance()).getString('token');
  }

  Future<Map<String, dynamic>> call(String method, String path,
      [Map<String, dynamic>? body]) async {
    final h = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token'
    };
    final u = Uri.parse('$base$path');
    // Daraja may need one OAuth request followed by the STK request. Give
    // payment initiation enough time to finish so the UI doesn't report a
    // timeout while Safaricom may already be processing the prompt.
    final requestTimeout =
        path.contains('/api/payments/') && path.endsWith('/initiate')
            ? const Duration(seconds: 35)
            : const Duration(seconds: 20);
    late http.Response r;
    if (method == 'POST') {
      r = await client
          .post(u, headers: h, body: jsonEncode(body ?? {}))
          .timeout(requestTimeout);
    } else if (method == 'PATCH') {
      r = await client
          .patch(u, headers: h, body: jsonEncode(body ?? {}))
          .timeout(requestTimeout);
    } else if (method == 'PUT') {
      // PUT supports idempotent business updates such as shared-inbox assignment and handover.
      r = await client
          .put(u, headers: h, body: jsonEncode(body ?? {}))
          .timeout(requestTimeout);
    } else if (method == 'DELETE') {
      r = await client
          .delete(u, headers: h, body: body == null ? null : jsonEncode(body))
          .timeout(requestTimeout);
    } else {
      r = await client.get(u, headers: h).timeout(requestTimeout);
    }
    // API routes must return JSON. Render/Vercel error pages and stale deployments
    // sometimes return HTML (starting with "<"), which jsonDecode would expose as
    // an unhelpful FormatException when the Business tab loads.
    dynamic decoded;
    if (r.body.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(r.body);
      } on FormatException {
        final contentType = r.headers['content-type'] ?? '';
        final bodyStart = r.body.trimLeft();
        final looksLikeHtml = contentType.contains('text/html') ||
            bodyStart.startsWith('<!DOCTYPE') ||
            bodyStart.startsWith('<html') ||
            bodyStart.startsWith('<');
        if (looksLikeHtml) {
          throw ApiException(
            r.statusCode,
            'Chatify API returned an HTML page instead of JSON for $path '
            '(HTTP ${r.statusCode}). This usually means the backend deployment '
            'is outdated or CHATIFY_API points to the wrong service. '
            'Check the Render deployment for https://chatify-api-c1eh.onrender.com '
            'and confirm it is running the latest main branch.',
          );
        }
        throw ApiException(r.statusCode,
            'Chatify API returned an invalid JSON response for $path '
            '(HTTP ${r.statusCode}).');
      }
    } else {
      decoded = <String, dynamic>{};
    }
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode,
          decoded is Map && decoded['error'] != null
              ? decoded['error'].toString()
              : 'Request failed (HTTP ${r.statusCode})');
    }
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : {'data': decoded};
  }

  Future<Map<String, dynamic>> paymentStatus(String paymentId) =>
      call('GET', '/api/payments/$paymentId');
}

String? normalizeKenyanPhone(String value) {
  final digits = value.trim().replaceAll(RegExp(r'[\s()+-]'), '');
  if (RegExp(r'^0[17]\d{8}$').hasMatch(digits)) {
    return '254${digits.substring(1)}';
  }
  if (RegExp(r'^\+?254[17]\d{8}$').hasMatch(digits)) {
    return digits.replaceFirst('+', '');
  }
  return null;
}

List<dynamic> mergeMessages(List<dynamic> current, List<dynamic> fetched) {
  final merged = <dynamic>[];
  final indices = <String, int>{};
  for (final message in [...current, ...fetched]) {
    if (message is! Map || message['_id'] == null) {
      merged.add(message);
      continue;
    }
    final id = message['_id'].toString();
    final index = indices[id];
    if (index == null) {
      indices[id] = merged.length;
      merged.add(message);
    } else {
      merged[index] = message;
    }
  }
  merged.sort((a, b) {
    if (a is! Map || b is! Map) return 0;
    final aDate = DateTime.tryParse(a['createdAt']?.toString() ?? '');
    final bDate = DateTime.tryParse(b['createdAt']?.toString() ?? '');
    if (aDate == null || bDate == null) return 0;
    return aDate.compareTo(bDate);
  });
  return merged;
}

// Resolve a reply reference only against messages loaded for the active conversation.
// Supporting both a raw ID and a populated reference keeps old and new API payloads readable.
Map<String, dynamic>? findReplyTarget(List<dynamic> conversationMessages, dynamic replyTo) {
  final replyId = replyTo is Map
      ? (replyTo['_id'] ?? replyTo['id'])?.toString()
      : replyTo?.toString();
  if (replyId == null || replyId.isEmpty) return null;
  for (final item in conversationMessages) {
    if (item is Map && item['_id']?.toString() == replyId) {
      return Map<String, dynamic>.from(item);
    }
  }
  return null;
}

List<dynamic> mergePayment(
    List<dynamic> current, Map<String, dynamic> payment) {
  final updated = List<dynamic>.from(current);
  final id = payment['paymentId']?.toString();
  if (id == null) return updated;
  final index = updated
      .indexWhere((item) => item is Map && item['paymentId']?.toString() == id);
  if (index < 0) {
    updated.insert(0, payment);
  } else {
    updated[index] = payment;
  }
  return updated;
}

// Resolve the display name for a direct conversation consistently in the chat list and chat header.
String? conversationPeerName(
    Map<String, dynamic> conversation, Map<String, dynamic>? currentUser) {
  if (conversation['type'] == 'group') return null;

  final currentIds = <String>{
    currentUser?['id']?.toString() ?? '',
    currentUser?['_id']?.toString() ?? '',
  }..remove('');
  final currentEmail = currentUser?['email']?.toString().trim().toLowerCase() ?? '';
  final rawParticipants = conversation['participants'];
  if (rawParticipants is! List) return null;

  String? firstAvailableName;
  for (final raw in rawParticipants) {
    if (raw is! Map) continue;
    final participant = Map<String, dynamic>.from(raw);
    final nested = participant['user'] is Map
        ? Map<String, dynamic>.from(participant['user'] as Map)
        : <String, dynamic>{};
    final id = (participant['_id'] ?? participant['id'] ??
            participant['userId'] ?? nested['_id'] ?? nested['id'])
        ?.toString() ?? '';
    final email = (participant['email'] ?? nested['email'])
        ?.toString().trim().toLowerCase() ?? '';
    final name = (participant['name'] ?? nested['name'] ??
            participant['displayName'] ?? nested['displayName'] ??
            participant['username'] ?? nested['username'])
        ?.toString().trim() ?? '';

    // Exclude the signed-in user by ID or email before choosing the chat peer.
    if ((id.isNotEmpty && currentIds.contains(id)) ||
        (currentEmail.isNotEmpty && email.isNotEmpty && email == currentEmail)) {
      continue;
    }
    if (name.isNotEmpty) return name;
    // Keep the first usable fallback name; null needs no explicit assignment.
  }
  return firstAvailableName;
}

// Shared app state. Screens listen to this object and rebuild after login, chat, contact, memory, or payment data changes.
class AppState extends ChangeNotifier {
  final Api api;
  bool ready = false;
  bool authRequested = false;
  bool startRegistration = false;
  Map<String, dynamic>? user;
  String? restoreError;
  final Set<String> onlineUserIds = {};
  io.Socket? _presenceSocket;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  String? _registeredPushToken;
  AppState({Api? api, bool autoInit = true}) : api = api ?? Api() {
    if (autoInit) init();
  }
  Future<void> init() async {
    ready = false;
    restoreError = null;
    await api.restore();
    if (api.token != null) {
      try {
        user = Map<String, dynamic>.from(
            (await api.call('GET', '/api/auth/me'))['user']);
      } catch (error) {
        if (error is ApiException && error.statusCode == 401) {
          await logout();
        } else {
          restoreError = error.toString();
        }
      }
    }
    if (user != null) {
      _connectPresence();
      await _initializePushNotifications();
    }
    ready = true;
    notifyListeners();
  }

  void _connectPresence() {
    final token = api.token;
    if (token == null || token.isEmpty) return;
    _presenceSocket?.dispose();
    onlineUserIds.clear();
    _presenceSocket = io.io(
      api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .enableReconnection()
          .build(),
    );
    _presenceSocket!.on('presence:initial', (data) {
      if (data is! Map || data['userIds'] is! List) return;
      onlineUserIds
        ..clear()
        ..addAll((data['userIds'] as List).map((id) => id.toString()));
      notifyListeners();
    });
    _presenceSocket!.on('user:online', (data) {
      if (data is Map && data['userId'] != null &&
          onlineUserIds.add(data['userId'].toString())) {
        notifyListeners();
      }
    });
    _presenceSocket!.on('user:offline', (data) {
      if (data is Map && data['userId'] != null &&
          onlineUserIds.remove(data['userId'].toString())) {
        notifyListeners();
      }
    });
    _presenceSocket!.onDisconnect((_) {
      if (onlineUserIds.isNotEmpty) {
        onlineUserIds.clear();
        notifyListeners();
      }
    });
    _presenceSocket!.connect();
  }

  Future<void> _initializePushNotifications() async {
    // Firebase is optional in development. Missing native Firebase configuration
    // must never prevent the user from signing in or using chat.
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) await _registerPushToken(token);
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = messaging.onTokenRefresh.listen((token) {
        unawaited(_registerPushToken(token));
      }, onError: (_) {});
      await _messageOpenedSubscription?.cancel();
      _messageOpenedSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen(_openConversationFromNotification);
      await _foregroundMessageSubscription?.cancel();
      _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((_) {
        chatifyScaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('You received a new message.')),
        );
      });
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        await _openConversationFromNotification(initialMessage);
      }
    } catch (_) {
      // No Firebase project or denied platform capability: chat remains usable.
    }
  }

  Future<void> _registerPushToken(String token) async {
    if (api.token == null || token.isEmpty) return;
    try {
      final previousToken = _registeredPushToken;
      await api.call('POST', '/api/devices', {'token': token});
      _registeredPushToken = token;
      if (previousToken != null && previousToken != token) {
        try {
          await api.call('DELETE', '/api/devices', {'token': previousToken});
        } catch (_) {
          // The newly registered token remains usable if stale-token cleanup fails.
        }
      }
    } catch (_) {
      // Registration is best-effort; a later token refresh or sign-in retries it.
    }
  }

  Future<void> _openConversationFromNotification(RemoteMessage message) async {
    final conversationId = message.data['conversationId']?.toString();
    if (conversationId == null || conversationId.isEmpty || api.token == null) {
      return;
    }
    try {
      final response = await api.call('GET', '/api/conversations');
      final conversations =
          List<dynamic>.from(response['conversations'] ?? const []);
      final matching = conversations.whereType<Map>().firstWhere(
            (item) => item['_id']?.toString() == conversationId,
            orElse: () => <String, dynamic>{},
          );
      if (matching.isEmpty) return;
      final navigator = chatifyNavigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => Chat(
          conversation: Map<String, dynamic>.from(matching),
        ),
      ));
    } catch (_) {
      // The server remains authoritative for conversation membership.
    }
  }

  Future<String?> auth(bool reg, String name, String email, String pass, String phone) async {
    try {
      final d = await api.call(
          'POST',
          reg ? '/api/auth/register' : '/api/auth/login',
          reg
              ? {'name': name, 'email': email, 'password': pass, 'phone': normalizeKenyanPhone(phone)}
              : {'email': email, 'password': pass});
      api.token = d['token'];
      user = Map<String, dynamic>.from(d['user']);
      await (await SharedPreferences.getInstance())
          .setString('token', api.token!);
      _connectPresence();
      await _initializePushNotifications();
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  void openAuth({bool register = false}) {
    authRequested = true;
    startRegistration = register;
    notifyListeners();
  }

  void returnToWelcome() {
    authRequested = false;
    startRegistration = false;
    notifyListeners();
  }

  Future<void> logout() async {
    final registeredToken = _registeredPushToken;
    if (registeredToken != null && api.token != null) {
      try {
        await api.call('DELETE', '/api/devices', {'token': registeredToken});
      } catch (_) {
        // Local sign-out must still complete when the API is unavailable.
      }
    }
    _registeredPushToken = null;
    _presenceSocket?.dispose();
    _presenceSocket = null;
    onlineUserIds.clear();
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    await _messageOpenedSubscription?.cancel();
    _messageOpenedSubscription = null;
    await _foregroundMessageSubscription?.cancel();
    _foregroundMessageSubscription = null;
    api.token = null;
    user = null;
    authRequested = false;
    startRegistration = false;
    restoreError = null;
    await (await SharedPreferences.getInstance()).remove('token');
    notifyListeners();
  }
}

final GlobalKey<NavigatorState> chatifyNavigatorKey =
    GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> chatifyScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() => runApp(ChangeNotifierProvider(
    create: (_) => AppState(), child: const ChatifyApp()));

// Root widget that configures app-wide Material styling and chooses the first screen.
class ChatifyApp extends StatelessWidget {
  const ChatifyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Chatify',
      navigatorKey: chatifyNavigatorKey,
      scaffoldMessengerKey: chatifyScaffoldMessengerKey,
      theme: ThemeData(
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF4F46E5),
          onPrimary: Colors.white,
          secondary: const Color(0xFF0F9D8A),
          onSecondary: Colors.white,
          surface: Colors.white,
          onSurface: const Color(0xFF172033),
          error: const Color(0xFFDC2626),
          outline: const Color(0xFFD9DFEA),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        canvasColor: const Color(0xFFF5F7FB),
        cardColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F7FB),
          foregroundColor: Color(0xFF172033),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Color(0xFF172033),
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: Color(0xFF172033),
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
          headlineMedium: TextStyle(
            color: Color(0xFF172033),
            fontWeight: FontWeight.w700,
            letterSpacing: -0.65,
          ),
          titleLarge: TextStyle(
            color: Color(0xFF172033),
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          titleMedium: TextStyle(
            color: Color(0xFF253047),
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: TextStyle(
            color: Color(0xFF253047),
            fontSize: 16,
            height: 1.45,
          ),
          bodyMedium: TextStyle(
            color: Color(0xFF536078),
            fontSize: 14,
            height: 1.45,
          ),
          bodySmall: TextStyle(
            color: Color(0xFF69758B),
            fontSize: 12,
            height: 1.4,
          ),
          labelLarge: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.05,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          hintStyle: const TextStyle(
            color: Color(0xFF8A94A8),
            fontSize: 14,
          ),
          labelStyle: const TextStyle(
            color: Color(0xFF536078),
            fontSize: 14,
          ),
          helperStyle: const TextStyle(
            color: Color(0xFF69758B),
            fontSize: 12,
          ),
          errorStyle: const TextStyle(
            color: Color(0xFFDC2626),
            fontSize: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFD9DFEA)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFD9DFEA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFF4F46E5), width: 1.6),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFDC2626)),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFDC2626), width: 1.6),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF4F46E5),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFE5E7EB),
            disabledForegroundColor: const Color(0xFF8A94A8),
            minimumSize: const Size(48, 50),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF344054),
            minimumSize: const Size(44, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            side: const BorderSide(color: Color(0xFFD9DFEA)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF4F46E5),
            minimumSize: const Size(40, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: const Color(0xFF536078),
            minimumSize: const Size(44, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFE9E8FF),
          elevation: 0,
          height: 70,
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF4F46E5),
          foregroundColor: Colors.white,
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF172033),
          contentTextStyle: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0xFFF0F2F8),
          selectedColor: const Color(0xFFE9E8FF),
          secondarySelectedColor: const Color(0xFFDDF7F1),
          disabledColor: const Color(0xFFF5F7FB),
          labelStyle: const TextStyle(
            color: Color(0xFF344054),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          side: const BorderSide(color: Color(0xFFE3E7EF)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        listTileTheme: ListTileThemeData(
          iconColor: const Color(0xFF536078),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFEAEDF3),
          thickness: 1,
          space: 1,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Color(0xFF4F46E5),
          linearTrackColor: Color(0xFFE9E8FF),
          circularTrackColor: Color(0xFFE9E8FF),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          titleTextStyle: const TextStyle(
            color: Color(0xFF172033),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      home: Consumer<AppState>(
        builder: (_, appState, __) {
          if (!appState.ready) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (appState.restoreError != null) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not restore your session.'),
                      const SizedBox(height: 12),
                      Text(appState.restoreError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: appState.init,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          if (appState.user != null) return const Home();
          if (appState.authRequested) {
            return Auth(startWithRegistration: appState.startRegistration);
          }
          return Welcome(
            onSignIn: () => appState.openAuth(),
            onGetStarted: () => appState.openAuth(register: true),
          );
        },
      ),
    );
}

// Public welcome/marketing screen shown before a user enters the authenticated app.
class Welcome extends StatelessWidget {
  const Welcome({
    super.key,
    required this.onSignIn,
    required this.onGetStarted,
  });

  final VoidCallback onSignIn;
  final VoidCallback onGetStarted;

  static const ink = Color(0xFF172033);
  static const muted = Color(0xFF68758B);
  static const violet = Color(0xFF5548E8);
  static const mint = Color(0xFF41D6B0);

  Future<void> _browseStore(BuildContext context) async {
    final slug = TextEditingController();
    final selected = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Shop a Chatify store'),
        content: TextField(
          controller: slug,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Store name / URL slug',
            hintText: 'e.g. baraka-books',
            helperText: 'Ask the business for its Chatify store slug.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Browse products')),
        ],
      ),
    );
    final value = slug.text.trim().toLowerCase();
    if (selected != true || value.isEmpty || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StorefrontPage(slug: value),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: LayoutBuilder(
        builder: (context, viewport) {
          final wide = viewport.maxWidth >= 820;
          final mobile = viewport.maxWidth < 600;
          return SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1160),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(mobile ? 16 : 30, 18, mobile ? 16 : 30, 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Container(
                          height: 42, width: 42,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0xFF7167F8), Color(0xFF4938D2)]),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.forum_rounded, color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 11),
                        const Text('Chatify', style: TextStyle(color: ink, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                        const Spacer(),
                        IconButton(tooltip: 'Shop a store', onPressed: () => _browseStore(context), icon: const Icon(Icons.storefront_outlined)),
                        TextButton(onPressed: onSignIn, child: const Text('Sign in')),
                        const SizedBox(width: 5),
                        FilledButton(
                          onPressed: onGetStarted,
                          style: FilledButton.styleFrom(
                            backgroundColor: violet,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                          ),
                          child: const Text('Create account'),
                        ),
                      ]),
                      SizedBox(height: wide ? 34 : 22),
                      if (wide)
                        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Expanded(
                            flex: 4,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 26),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(color: const Color(0xFFE8E6FF), borderRadius: BorderRadius.circular(30)),
                                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.circle, color: Color(0xFF35C997), size: 8),
                                    SizedBox(width: 7),
                                    Text('YOUR PEOPLE, RIGHT HERE', style: TextStyle(color: Color(0xFF4D42B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                                  ]),
                                ),
                                const SizedBox(height: 20),
                                const Text('Just chat.', style: TextStyle(color: ink, fontSize: 54, height: 1.0, fontWeight: FontWeight.w900, letterSpacing: -2.8)),
                                const SizedBox(height: 10),
                                const Text('The moments matter.', style: TextStyle(color: violet, fontSize: 30, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -1.2)),
                                const SizedBox(height: 16),
                                const Text('Real conversations. Memories worth keeping.', style: TextStyle(color: muted, fontSize: 14, height: 1.6)),
                                const SizedBox(height: 24),
                                FilledButton.icon(
                                  onPressed: onGetStarted,
                                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                                  label: const Text('Start chatting'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: violet,
                                    minimumSize: const Size(190, 50),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                          const Expanded(flex: 6, child: _ConversationPreview()),
                        ])
                      else ...[
                        const Text('Your people. Your conversations.', style: TextStyle(color: ink, fontSize: 27, height: 1.1, fontWeight: FontWeight.w900, letterSpacing: -1)),
                        const SizedBox(height: 7),
                        const Text('Chat, remember, let go.', style: TextStyle(color: muted, fontSize: 13)),
                        const SizedBox(height: 20),
                        const _ConversationPreview(),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: onGetStarted,
                          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                          label: const Text('Start chatting'),
                          style: FilledButton.styleFrom(
                            backgroundColor: violet,
                            minimumSize: const Size.fromHeight(50),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.lock_outline_rounded, color: muted, size: 15),
                        SizedBox(width: 7),
                        Flexible(child: Text('Private by design · Yours to manage', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w600))),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }


}

// Small illustrative conversation used by the welcome screen; it is presentation-only, not a real chat.
class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          colors: [Color(0xFF292C57), Color(0xFF151B30)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x1C292C57), blurRadius: 44, offset: Offset(0, 22)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.forum_rounded, color: Welcome.mint, size: 20),
              const SizedBox(width: 8),
              const Text('A little preview', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(color: const Color(0x223DD7B0), borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Icon(Icons.circle, color: Welcome.mint, size: 7),
                    SizedBox(width: 6),
                    Text('CONNECTED', style: TextStyle(color: Welcome.mint, fontSize: 9, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [Color(0xFF79D8C1), Color(0xFF6C85E8)]),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(Icons.people_alt_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Weekend plans', style: TextStyle(color: Welcome.ink, fontWeight: FontWeight.w800)),
                          SizedBox(height: 3),
                          Text('Maya, Alex · 3 members', style: TextStyle(color: Welcome.muted, fontSize: 11)),
                        ],
                      ),
                    ),
                    const Icon(Icons.more_horiz, color: Welcome.muted),
                  ],
                ),
                const SizedBox(height: 20),
                const _PreviewBubble(
                  initials: 'M',
                  name: 'Maya',
                  text: 'Let’s meet at 10 on Saturday ☀️',
                  mine: false,
                ),
                const SizedBox(height: 10),
                const _PreviewBubble(
                  initials: 'Y',
                  name: 'You',
                  text: 'Perfect! I’ll save that so we don’t forget.',
                  mine: true,
                ),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5FBF4),
                    border: Border.all(color: const Color(0xFFC8F1E6)),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.auto_awesome_rounded, color: Color(0xFF087F6A), size: 19),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('MEMORY CARD', style: TextStyle(color: Color(0xFF087F6A), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
                            SizedBox(height: 5),
                            Text('Saturday · 10:00 AM', style: TextStyle(color: Color(0xFF17483E), fontSize: 14, fontWeight: FontWeight.w800)),
                            SizedBox(height: 3),
                            Text('A detail worth keeping, right when you need it.', style: TextStyle(color: Color(0xFF4F766D), fontSize: 11, height: 1.45)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.add_circle_outline_rounded, color: Color(0xFF929AAF), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(color: const Color(0xFFF4F6FA), borderRadius: BorderRadius.circular(13)),
                        child: const Text('Write a message…', style: TextStyle(color: Color(0xFF929AAF), fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 38,
                      width: 38,
                      decoration: BoxDecoration(color: Welcome.violet, borderRadius: BorderRadius.circular(13)),
                      child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 19),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline_rounded, color: Color(0xFFBAC3E5), size: 14),
              SizedBox(width: 7),
              Text('Your conversations, with you in control', style: TextStyle(color: Color(0xFFBAC3E5), fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}

// Reusable message bubble for the welcome-screen preview.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.initials,
    required this.name,
    required this.text,
    required this.mine,
  });
  final String initials;
  final String name;
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!mine) ...[
          CircleAvatar(radius: 15, backgroundColor: const Color(0xFFE7E8FF), child: Text(initials, style: const TextStyle(color: Welcome.violet, fontSize: 11, fontWeight: FontWeight.w800))),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFFE9E8FF) : const Color(0xFFF3F5FA),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(15),
                topRight: const Radius.circular(15),
                bottomLeft: Radius.circular(mine ? 15 : 5),
                bottomRight: Radius.circular(mine ? 5 : 15),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(color: Welcome.violet, fontSize: 10, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(text, style: const TextStyle(color: Welcome.ink, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// Reusable icon-and-text item for the welcome screen's feature/trust list.
class Auth extends StatefulWidget {
  const Auth({super.key, this.startWithRegistration = false});
  final bool startWithRegistration;
  @override
  State<Auth> createState() => _AuthState();
}

// Validates the form, calls the authentication API, and updates AppState after success.
class _AuthState extends State<Auth> {
  late bool reg;
  bool busy = false, hide = true;

  @override
  void initState() {
    super.initState();
    reg = widget.startWithRegistration;
  }
  final n = TextEditingController(),
      e = TextEditingController(),
      p = TextEditingController(),
      mpesaPhone = TextEditingController();
  @override
  void dispose() {
    n.dispose();
    e.dispose();
    p.dispose();
    mpesaPhone.dispose();
    super.dispose();
  }

  Future<void> recover() async {
    final email = TextEditingController(text: e.text.trim());
    final token = TextEditingController();
    final password = TextEditingController();
    var requested = false;
    final key = GlobalKey<FormState>();
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Reset password'),
                content: Form(
                    key: key,
                    child: TextFormField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration:
                            const InputDecoration(labelText: 'Account email'),
                        validator: (v) => v == null || !v.contains('@')
                            ? 'Enter a valid email'
                            : '')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (!key.currentState!.validate()) return;
                        try {
                          await context.read<AppState>().api.call(
                              'POST',
                              '/api/auth/forgot-password',
                              {'email': email.text.trim()});
                          requested = true;
                          if (d.mounted) Navigator.pop(d);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'If the account exists, reset instructions will be sent.')));
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.toString())));
                          }
                        }
                      },
                      child: const Text('Send instructions'))
                ]));
    email.dispose();
    if (requested && mounted) {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Choose a new password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: token,
                        decoration:
                            const InputDecoration(labelText: 'Reset token')),
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await context.read<AppState>().api.call(
                                'POST', '/api/auth/reset-password', {
                              'token': token.text.trim(),
                              'newPassword': password.text
                            });
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Password updated. Sign in with your new password.')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Reset password'))
                  ]));
    }
    token.dispose();
    password.dispose();
  }

  Future<void> submit() async {
    if (e.text.trim().isEmpty ||
        p.text.length < 8 ||
        (reg && (n.text.trim().isEmpty || normalizeKenyanPhone(mpesaPhone.text) == null))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Complete all fields. Password must be 8+ characters.')));
      return;
    }
    setState(() => busy = true);
    final err = await context
        .read<AppState>()
        .auth(reg, n.text.trim(), e.text.trim(), p.text, mpesaPhone.text.trim());
    if (mounted) {
      setState(() => busy = false);
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFE8EBF3)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0D172033),
                        blurRadius: 36,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          height: 56,
                          width: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF6259F5), Color(0xFF4338CA)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x264F46E5),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.forum_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Chatify',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF172033),
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Chat. Remember. Let Go.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF69758B),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        reg ? 'Create your account' : 'Welcome back',
                        style: const TextStyle(
                          color: Color(0xFF172033),
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.55,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        reg
                            ? 'Join the conversation and keep what matters.'
                            : 'Sign in to pick up where your conversations left off.',
                        style: const TextStyle(
                          color: Color(0xFF69758B),
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (reg)
                        TextField(
                          controller: n,
                          autofillHints: const [AutofillHints.name],
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                        ),
                      if (reg) const SizedBox(height: 10),
                      if (reg)
                        TextField(
                          controller: mpesaPhone,
                          keyboardType: TextInputType.phone,
                          autofillHints: const [AutofillHints.telephoneNumber],
                          decoration: const InputDecoration(
                            labelText: 'M-Pesa phone number',
                            hintText: '0712345678 or 254712345678',
                            helperText:
                                'Your default payment number. You can change it per request.',
                            prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                          ),
                        ),
                      if (reg) const SizedBox(height: 10),
                      TextField(
                        controller: e,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: p,
                        obscureText: hide,
                        autofillHints: [
                          reg ? AutofillHints.newPassword : AutofillHints.password,
                        ],
                        onSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: hide ? 'Show password' : 'Hide password',
                            onPressed: () => setState(() => hide = !hide),
                            icon: Icon(
                              hide
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(reg ? 'Create account' : 'Sign in'),
                      ),
                      if (!reg)
                        Align(
                          alignment: Alignment.center,
                          child: TextButton(
                            onPressed: busy ? null : recover,
                            child: const Text('Forgot password?'),
                          ),
                        ),
                      const SizedBox(height: 0),
                      const Divider(),
                      const SizedBox(height: 2),
                      TextButton(
                        onPressed: busy ? null : () => setState(() => reg = !reg),
                        child: Text(
                          reg
                              ? 'Already have an account? Sign in'
                              : 'Create a new account',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => context.read<AppState>().returnToWelcome(),
                        icon: const Icon(Icons.arrow_back_rounded, size: 17),
                        label: const Text('Back to homepage'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

// Main authenticated workspace containing chats, contacts and saved memories.
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

// Coordinates the Home tabs and selections, and loads the data displayed in each section.
class _HomeState extends State<Home> {
  int tab = 0;
  List<dynamic> chats = [], users = [], memories = [];
  bool loading = false;
  bool selectingChats = false;
  final Set<String> selectedConversationIds = {};
  bool memoriesLoading = false, usersLoading = false;
  String contactQuery = '';
  String phoneQuery = '';
  List<dynamic> savedContacts = [], phoneResults = [];
  bool contactsLoading = false, phoneSearching = false;
  Timer? _phoneSearchDebounce;
  String? chatsError, memoriesError, usersError;
  AppState get app => context.read<AppState>();
  @override
  void initState() {
    super.initState();
    loadChats();
    loadSavedContacts();
  }

  void _toggleConversationSelection(String id) {
    setState(() {
      if (!selectedConversationIds.add(id)) selectedConversationIds.remove(id);
      if (selectedConversationIds.isEmpty) selectingChats = false;
    });
  }

  Future<void> _deleteSelectedConversations() async {
    final ids = selectedConversationIds.toList();
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete ${ids.length} conversation${ids.length == 1 ? '' : 's'}?'),
        content: Text('This removes the selected conversation${ids.length == 1 ? '' : 's'} from your chat list only. Other participants keep their copies. A new message can make a conversation appear again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Delete for me')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.api.call('POST', '/api/conversations/delete', {'conversationIds': ids});
      setState(() { chats.removeWhere((c) => c is Map && ids.contains(c['_id']?.toString())); selectedConversationIds.clear(); selectingChats = false; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${ids.length} conversation${ids.length == 1 ? '' : 's'} deleted from your chat list.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> loadChats() async {
    setState(() => loading = true);
    try {
      chats = List<dynamic>.from(
          (await app.api.call('GET', '/api/conversations'))['conversations'] ??
              []);
      chatsError = null;
    } catch (error) {
      chatsError = error.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> search(String q) async {
    contactQuery = q;
    if (q.trim().length < 2) {
      setState(() {
        users = [];
        usersError = null;
        usersLoading = false;
      });
      return;
    }
    setState(() {
      usersLoading = true;
      usersError = null;
    });
    try {
      final found = List<dynamic>.from((await app.api.call('GET',
                  '/api/users/search?q=${Uri.encodeQueryComponent(q.trim())}'))[
              'users'] ??
          []);
      if (mounted && contactQuery == q) setState(() => users = found);
    } catch (error) {
      if (mounted && contactQuery == q) {
        setState(() => usersError = error.toString());
      }
    } finally {
      if (mounted && contactQuery == q) setState(() => usersLoading = false);
    }
  }

  Future<void> loadMemories() async {
    setState(() => memoriesLoading = true);
    try {
      memories = List<dynamic>.from(
          (await app.api.call('GET', '/api/memories'))['memories'] ?? []);
      memoriesError = null;
      if (mounted) setState(() {});
    } catch (error) {
      memoriesError = error.toString();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => memoriesLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['Chats', 'Business', 'Memories', 'Contacts', 'Profile'];
    return Scaffold(
      // Keep Business discoverable from the primary chat screen as well as the
      // dedicated bottom-navigation tab. This is especially helpful on web,
      // where users may overlook the fifth navigation destination.
      floatingActionButton: tab == 0
          ? FloatingActionButton.extended(
              heroTag: 'open-business-workspace',
              onPressed: () => setState(() => tab = 1),
              icon: const Icon(Icons.business_center_outlined),
              label: const Text('Business'),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          if (tab != 1)
            IconButton(
              tooltip: 'Open Business workspace',
              icon: const Icon(Icons.business_center_outlined),
              onPressed: () => setState(() => tab = 1),
            ),
          IconButton(
              tooltip: 'Payment history',
              icon: const Icon(Icons.account_balance_wallet_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PaymentHistory()))),
          if (tab == 0 && selectingChats) ...[
            IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: () => setState(() { selectedConversationIds..clear()..addAll(chats.whereType<Map>().map((c) => c['_id'].toString())); })),
            IconButton(tooltip: 'Delete selected conversations', onPressed: selectedConversationIds.isEmpty ? null : _deleteSelectedConversations, icon: const Icon(Icons.delete_outline)),
            IconButton(tooltip: 'Cancel selection', onPressed: () => setState(() { selectingChats = false; selectedConversationIds.clear(); }), icon: const Icon(Icons.close)),
          ] else if (tab == 0) ...[
            IconButton(tooltip: 'Select conversations', onPressed: () => setState(() => selectingChats = true), icon: const Icon(Icons.checklist)),
            IconButton(onPressed: loadChats, icon: const Icon(Icons.refresh)),
          ],
          if (tab == 3)
            IconButton(onPressed: _newGroup, icon: const Icon(Icons.group_add)),
        ],
      ),
      body: IndexedStack(
          index: tab,
          children: [_chats(), const BusinessHub(), _memories(), _contacts(), const Profile()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() => tab = i);
          if (i == 0) loadChats();
          if (i == 2) loadMemories();
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
          NavigationDestination(
              icon: Icon(Icons.business_center_outlined), label: 'Business'),
          NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined), label: 'Memories'),
          NavigationDestination(
              icon: Icon(Icons.people_outline), label: 'Contacts'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }

  Widget _chats() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (chatsError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(chatsError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: loadChats, child: const Text('Retry'))
      ]));
    }
    if (chats.isEmpty) {
      return const Empty(
          icon: Icons.forum_outlined,
          title: 'No conversations',
          subtitle: 'Search Contacts to start a chat.');
    }
    return RefreshIndicator(
      onRefresh: loadChats,
      child: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (_, i) {
          final c = Map<String, dynamic>.from(chats[i]);
          // Use the same ID/email-aware peer resolver as the conversation header.
          // Older API payloads can expose participant IDs as either id or _id.
          final title = c['type'] == 'group'
              ? (c['title'] ?? 'Group').toString()
              : (conversationPeerName(c, app.user) ?? 'Unknown user').toString();
          final last = c['lastMessage'];
          final preview = last is Map
              ? (last['text'] ?? 'Start chatting').toString()
              : 'Start chatting';
          final id = c['_id']?.toString() ?? '';
          final selected = selectedConversationIds.contains(id);
          return ListTile(
            leading: selectingChats
                ? Checkbox(value: selected, onChanged: (_) => _toggleConversationSelection(id))
                : CircleAvatar(child: Text(title.isEmpty ? '?' : title[0].toUpperCase())),
            title: Text(title),
            subtitle: Text(preview),
            selected: selected,
            onLongPress: () {
              if (!selectingChats) setState(() => selectingChats = true);
              _toggleConversationSelection(id);
            },
            onTap: () {
              if (selectingChats) { _toggleConversationSelection(id); return; }
              Navigator.push(context,
                      MaterialPageRoute(builder: (_) => Chat(conversation: c)))
                  .then((_) => loadChats());
            },
          );
        },
      ),
    );
  }

  Future<void> loadSavedContacts() async {
    if (mounted) setState(() => contactsLoading = true);
    try {
      final result = await app.api.call('GET', '/api/contacts');
      if (mounted) setState(() => savedContacts = List<dynamic>.from(result['contacts'] ?? []));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load contacts: $error')));
    } finally { if (mounted) setState(() => contactsLoading = false); }
  }

  @override
  void dispose() {
    _phoneSearchDebounce?.cancel();
    super.dispose();
  }

  Future<void> searchPhone([String? query]) async {
    final value = (query ?? phoneQuery).trim();
    if (query != null) phoneQuery = query;
    if (value.replaceAll(RegExp(r'\D'), '').length < 3) {
      if (mounted) setState(() { phoneResults = []; phoneSearching = false; });
      return;
    }
    setState(() => phoneSearching = true);
    try {
      final result = await app.api.call('GET', '/api/contacts/search?q=${Uri.encodeQueryComponent(value)}');
      if (mounted && phoneQuery.trim() == value) setState(() => phoneResults = List<dynamic>.from(result['users'] ?? []));
    } catch (error) {
      if (mounted && phoneQuery.trim() == value) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && phoneQuery.trim() == value) setState(() => phoneSearching = false);
    }
  }

  Future<void> savePhoneContact(String phone) async {
    try {
      await app.api.call('POST', '/api/contacts', {'phone': phone});
      await loadSavedContacts();
      if (mounted) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _openUserChat(String userId) async {
    try {
      final result = await app.api.call(
        'POST',
        '/api/conversations/direct',
        {'userId': userId},
      );
      if (!mounted) return;
      final conversation = Map<String, dynamic>.from(result['conversation']);
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => Chat(conversation: conversation)),
      );
      if (mounted) loadChats();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    }
  }

  Future<void> saveUserContact(String userId) async {
    try {
      await app.api.call('POST', '/api/contacts', {'userId': userId});
      await loadSavedContacts();
      if (mounted) {
        // Keep live search results visible so another matching account can be
        // selected without retyping the query.
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> removeSavedContact(Map<String, dynamic> contact) async {
    try { await app.api.call('DELETE', '/api/contacts/${contact['id']}'); await loadSavedContacts(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString()))); }
  }

  Widget _contacts() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: TextField(
          keyboardType: TextInputType.phone,
          onChanged: (value) {
            phoneQuery = value;
            _phoneSearchDebounce?.cancel();
            _phoneSearchDebounce = Timer(
              const Duration(milliseconds: 300),
              () => searchPhone(value),
            );
          },
          onSubmitted: (_) => searchPhone(),
          decoration: InputDecoration(
            labelText: 'Find by phone number',
            hintText: 'Type a number, e.g. 0712 or +254712',
            prefixIcon: const Icon(Icons.phone),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Search phone number',
              onPressed: phoneSearching ? null : searchPhone,
              icon: phoneSearching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
            ),
          ),
        ),
      ),
      if (phoneQuery.trim().replaceAll(RegExp(r'\D'), '').length >= 3 &&
          phoneSearching)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: LinearProgressIndicator(),
        ),
      if (phoneQuery.trim().replaceAll(RegExp(r'\D'), '').length >= 3 &&
          !phoneSearching &&
          phoneResults.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('No accounts match that number yet. Keep typing or check the digits.'),
          ),
        ),
      if (phoneResults.isNotEmpty)
        SizedBox(
          height: phoneResults.length > 2 ? 144.0 : phoneResults.length * 68.0,
          child: ListView.builder(
            itemCount: phoneResults.length,
            itemBuilder: (_, i) {
              final person = Map<String, dynamic>.from(phoneResults[i]);
              final name = person['name']?.toString() ?? 'Chatify user';
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                ),
                title: Text(name),
                subtitle: Text(person['phone']?.toString() ?? ''),
                trailing: IconButton(
                  tooltip: 'Save contact',
                  icon: const Icon(Icons.person_add_alt_1),
                  onPressed: () => savePhoneContact(
                    person['phone']?.toString() ?? phoneQuery,
                  ),
                ),
              );
            },
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(
          onChanged: search,
          decoration: const InputDecoration(
            labelText: 'Search by user name or email',
            hintText: 'Type at least 2 letters',
            prefixIcon: Icon(Icons.person_search),
            border: OutlineInputBorder(),
          ),
        ),
      ),
      if (contactQuery.trim().length >= 2)
        SizedBox(
          height: 156,
          child: usersLoading
              ? const Center(child: CircularProgressIndicator())
              : usersError != null
                  ? Center(child: Text(usersError!))
                  : users.isEmpty
                      ? Center(
                          child: Text(
                            'No registered users match “${contactQuery.trim()}”.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: users.length,
                          itemBuilder: (_, i) {
                            final user = Map<String, dynamic>.from(users[i]);
                            final name = user['name']?.toString() ?? 'User';
                            final userId = user['_id']?.toString() ??
                                user['id']?.toString() ??
                                '';
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.person_outline),
                              title: Text(name),
                              subtitle: Text(user['email']?.toString() ?? ''),
                              onTap: userId.isEmpty
                                  ? null
                                  : () => _openUserChat(userId),
                              trailing: Wrap(
                                spacing: 0,
                                children: [
                                  IconButton(
                                    tooltip: 'Save contact',
                                    icon: const Icon(Icons.person_add_alt_1),
                                    onPressed: userId.isEmpty
                                        ? null
                                        : () => saveUserContact(userId),
                                  ),
                                  IconButton(
                                    tooltip: 'Chat now',
                                    icon: const Icon(Icons.chat_bubble_outline),
                                    onPressed: userId.isEmpty
                                        ? null
                                        : () => _openUserChat(userId),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Saved contacts',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            IconButton(
              tooltip: 'Refresh contacts',
              onPressed: loadSavedContacts,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      Expanded(
        child: contactsLoading
            ? const Center(child: CircularProgressIndicator())
            : savedContacts.isEmpty
                ? const Empty(
                    icon: Icons.contacts_outlined,
                    title: 'No saved contacts',
                    subtitle:
                        'Search for a registered phone number or user name and save it here.',
                  )
                : ListView.builder(
                    itemCount: savedContacts.length,
                    itemBuilder: (_, i) {
                      final contact =
                          Map<String, dynamic>.from(savedContacts[i]);
                      final name = contact['name']?.toString() ?? 'Contact';
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                        ),
                        title: Text(name),
                        subtitle: Text(
                          contact['phone']?.toString() ??
                              contact['email']?.toString() ??
                              '',
                        ),
                        onTap: () async {
                          try {
                            final result = await app.api.call(
                              'POST',
                              '/api/conversations/direct',
                              {'userId': contact['userId']},
                            );
                            if (!mounted) return;
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => Chat(
                                  conversation: Map<String, dynamic>.from(
                                    result['conversation'],
                                  ),
                                ),
                              ),
                            ).then((_) => loadChats());
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(error.toString())),
                              );
                            }
                          }
                        },
                        trailing: IconButton(
                          tooltip: 'Remove contact',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () => removeSavedContact(contact),
                        ),
                      );
                    },
                  ),
      ),
    ]);
  }

  Widget _memories() {
    if (memoriesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (memoriesError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(memoriesError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: loadMemories, child: const Text('Retry'))
      ]));
    }
    if (memories.isEmpty) {
      return const Empty(
          icon: Icons.auto_awesome,
          title: 'No memories saved',
          subtitle: 'Save useful events, tasks, places and payments.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: memories.length,
      itemBuilder: (_, i) {
        final memory = Map<String, dynamic>.from(memories[i]);
        return Dismissible(
          key: ValueKey(memory['_id']),
          direction: DismissDirection.endToStart,
          background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete_outline)),
          onDismissed: (_) async {
            try {
              await app.api.call('DELETE', '/api/memories/${memory['_id']}');
            } catch (_) {}
          },
          child: Card(
              child: ListTile(
                  title: Text(memory['title']?.toString() ?? 'Memory'),
                  subtitle: Text(memory['description']?.toString() ?? ''))),
        );
      },
    );
  }

  Future<void> _newGroup() async {
    final title = TextEditingController();
    final emails = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Create group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Group name')),
            TextField(
                controller: emails,
                keyboardType: TextInputType.emailAddress,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: 'Member emails',
                    helperText: 'Separate addresses with commas or new lines')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final memberEmails = emails.text
                    .split(RegExp(r'[,;\n]'))
                    .map((value) => value.trim().toLowerCase())
                    .where((value) => value.isNotEmpty)
                    .toSet();
                if (memberEmails.isEmpty) {
                  throw Exception('Enter at least one member email');
                }
                final memberIds = <String>[];
                for (final memberEmail in memberEmails) {
                  final result = await app.api.call('GET',
                      '/api/users/search?q=${Uri.encodeQueryComponent(memberEmail)}');
                  final found = List<dynamic>.from(result['users'] ?? []);
                  final match = found.where((user) =>
                      user is Map &&
                      user['email']?.toString().toLowerCase() == memberEmail);
                  if (match.isEmpty) {
                    throw Exception('No account found for $memberEmail');
                  }
                  memberIds.add(match.first['_id'].toString());
                }
                final created =
                    await app.api.call('POST', '/api/conversations/group', {
                  'title': title.text.trim(),
                  'memberIds': memberIds,
                });
                if (dialog.mounted) Navigator.pop(dialog);
                if (!mounted) return;
                Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Chat(
                          conversation: Map<String, dynamic>.from(
                              created['conversation'])),
                    ));
              } catch (error) {
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(error.toString())));
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    title.dispose();
    emails.dispose();
  }
}

// Consistent empty-state message for screens that have no records to display yet.
class Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const Empty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 84,
                width: 84,
                decoration: BoxDecoration(
                  color: const Color(0xFFE9E8FF),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(
                  icon,
                  size: 38,
                  color: const Color(0xFF4F46E5),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 21,
                      letterSpacing: -0.4,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF69758B),
                      height: 1.55,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Displays payment requests and their current statuses for the signed-in user.
class PaymentHistory extends StatefulWidget {
  const PaymentHistory({super.key});
  @override
  State<PaymentHistory> createState() => _PaymentHistoryState();
}

// Loads payment history and refreshes the list when payment data changes.
class _PaymentHistoryState extends State<PaymentHistory> {
  List<dynamic> payments = [];
  bool loading = true;
  String? error;
  Future<void> load() async {
    try {
      final result =
          await context.read<AppState>().api.call('GET', '/api/payments');
      if (mounted) {
        setState(() {
          payments = List<dynamic>.from(result['payments'] ?? []);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Payment history'), actions: [
        IconButton(onPressed: load, icon: const Icon(Icons.refresh))
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : payments.isEmpty
                  ? const Empty(
                      icon: Icons.payments_outlined,
                      title: 'No payments yet',
                      subtitle: 'Requests and payments will appear here.')
                  : RefreshIndicator(
                      onRefresh: load,
                      child: ListView.builder(
                          itemCount: payments.length,
                          itemBuilder: (_, i) {
                            final p = Map<String, dynamic>.from(payments[i]);
                            return PaymentCard(
                                payment: p,
                                currentUserId: app.user?['id']?.toString(),
                                onPay: () => payHistoryPayment(p),
                                onRetry: () => retryHistoryPayment(p),
                                onRefresh: () async {
                                  try {
                                    final result = await app.api.paymentStatus(
                                        p['paymentId'].toString());
                                    final index = payments.indexWhere((item) =>
                                        item is Map &&
                                        item['paymentId'] == p['paymentId']);
                                    if (mounted && index >= 0) {
                                      setState(() =>
                                          payments[index] = result['payment']);
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      messenger.showSnackBar(SnackBar(
                                          content: Text(e.toString())));
                                    }
                                  }
                                });
                          }),
                    ),
    );
  }

  Future<void> payHistoryPayment(Map<String, dynamic> payment) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final phone = TextEditingController(
      text: payment['payerPhone']?.toString() ??
          payment['phone']?.toString() ??
          app.user?['phone']?.toString() ??
          '',
    );
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Pay with M-Pesa'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Your M-Pesa phone number',
              hintText: '0712345678 or 254712345678',
              helperText: 'The STK prompt will be sent to this number.',
            ),
            validator: (value) => normalizeKenyanPhone(value ?? '') == null
                ? 'Enter a valid Kenyan M-Pesa number'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(dialog, true);
              }
            },
            child: const Text('Send prompt'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) {
      phone.dispose();
      return;
    }
    try {
      final result = await app.api.call(
        'POST',
        '/api/payments/${payment['paymentId']}/initiate',
        {'phone': normalizeKenyanPhone(phone.text)!},
      );
      final updated = Map<String, dynamic>.from(result['payment']);
      final index = payments.indexWhere(
          (item) => item is Map && item['paymentId'] == updated['paymentId']);
      if (mounted && index >= 0) setState(() => payments[index] = updated);
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(result['mock'] == true
              ? 'Local demo only: no Safaricom prompt was sent. Configure live Daraja on the API service to send real prompts.'
              : 'STK request accepted. Check ${normalizeKenyanPhone(phone.text)} for the Safaricom prompt. Enter your PIN only in that prompt.'),
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      phone.dispose();
    }
  }

  Future<void> retryHistoryPayment(Map<String, dynamic> payment) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/retry', {});
      final created = Map<String, dynamic>.from(result['payment']);
      if (mounted) setState(() => payments.insert(0, created));
      if (mounted) await payHistoryPayment(created);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}

// Presents one payment request, its amount, participants and status in a compact card.
class PaymentCard extends StatelessWidget {
  final Map<String, dynamic> payment;
  final String? currentUserId;
  final VoidCallback? onPay;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final VoidCallback? onReject;
  final VoidCallback? onReopen;
  final String? rejectLabel;
  final VoidCallback onRefresh;
  const PaymentCard({
    super.key,
    required this.payment,
    required this.currentUserId,
    required this.onRefresh,
    this.onPay,
    this.onRetry,
    this.onClose,
    this.onReject,
    this.onReopen,
    this.rejectLabel,
  });

  @override
  Widget build(BuildContext context) {
    final status = (payment['status'] ?? 'PENDING').toString();
    final isPayer = payment['payerId']?.toString() == currentUserId;
    final isMock = payment['provider']?.toString() == 'mock';
    final canReject = status == 'PENDING' &&
        payment['initiatedAt'] == null &&
        payment['initiating'] != true &&
        onReject != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.payments_outlined),
              title: Text(payment['description']?.toString() ?? 'M-Pesa payment'),
              subtitle: Text(
                'KSh ${payment['amount'] ?? ''} · $status · To ${payment['recipientPhone'] ?? 'recipient'}${isMock ? ' · Local demo' : ''}',
              ),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                if (onReopen != null)
                  TextButton.icon(
                    onPressed: onReopen,
                    icon: const Icon(Icons.unarchive_outlined, size: 18),
                    label: const Text('Reopen request'),
                  ),
                if (onReopen == null &&
                    status == 'PENDING' && isPayer && onPay != null)
                  TextButton(
                    onPressed: onPay,
                    child: const Text('Pay with M-Pesa'),
                  ),
                if (onReopen == null &&
                    (status == 'FAILED' || status == 'CANCELLED') &&
                    isPayer &&
                    onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
                if (onReopen == null && canReject)
                  TextButton.icon(
                    onPressed: onReject,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: Text(rejectLabel ?? 'Reject request'),
                  ),
                if (onReopen == null && onClose != null)
                  TextButton.icon(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Close for me'),
                  ),
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Status'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Screen for one direct or group conversation, including messages and the composer.
class Chat extends StatefulWidget {
  final Map<String, dynamic> conversation;
  const Chat({super.key, required this.conversation});
  @override
  State<Chat> createState() => _ChatState();
}

// Owns the active conversation UI: loads messages, listens for real-time events, and sends message actions.
class _ChatState extends State<Chat> {
  final input = TextEditingController();
  final searchInput = TextEditingController();
  final ScrollController _messagesScrollController = ScrollController();
  Timer? _typingTimer;
  Timer? _remoteTypingTimer;
  bool _isTyping = false;
  List<dynamic> messages = [];
  List<dynamic> payments = [];
  // Suggestions remain in UI state until the user explicitly saves a Memory Card.
  List<Map<String, dynamic>> memorySuggestions = [];
  String? memorySuggestionSourceId;
  bool savingMemorySuggestion = false;
  final Set<String> _checkedMemoryMessageIds = {};
  final Set<String> _dismissedMemoryMessageIds = {};
  final Set<String> _savedMemoryMessageIds = {};
  bool showClosedPayments = false;
  String expiry = 'NONE';
  String? reply;
  String? typingUser;
  bool searching = false;
  bool sending = false;
  final Set<String> onlineIds = {};
  io.Socket? socket;
  bool loading = true;
  String? loadError;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    app.addListener(_syncPresence);
    _syncPresence();
    load();
    connect();
  }

  // Resolve the other member from the conversation payload. The API normally
  // populates participants with user names, but support both id/_id and nested
  // user objects so the header still works across older conversation responses.
  String? _directPeerName() {
    if (widget.conversation['type'] != 'direct') return null;
    final participants = widget.conversation['participants'];
    if (participants is! List) return null;

    final currentUserIds = <String>{
      app.user?['id']?.toString() ?? '',
      app.user?['_id']?.toString() ?? '',
    }..remove('');
    Map<String, dynamic>? fallbackParticipant;

    for (final rawParticipant in participants) {
      if (rawParticipant is! Map) continue;
      final participant = Map<String, dynamic>.from(rawParticipant);
      final nestedUser = participant['user'] is Map
          ? Map<String, dynamic>.from(participant['user'] as Map)
          : <String, dynamic>{};
      final rawId = participant['_id'] ??
          participant['id'] ??
          nestedUser['_id'] ??
          nestedUser['id'];
      final participantId = rawId?.toString() ?? '';

      // Never accidentally show the signed-in user's own name as the chat peer.
      if (participantId.isNotEmpty && currentUserIds.contains(participantId)) {
        continue;
      }
      fallbackParticipant ??= participant;

      final name = (participant['name'] ??
              nestedUser['name'] ??
              participant['username'] ??
              nestedUser['username'] ??
              participant['displayName'] ??
              nestedUser['displayName'] ??
              '')
          .toString()
          .trim();
      if (name.isNotEmpty) return name;
    }

    final fallback = fallbackParticipant;
    if (fallback == null) return null;
    final nestedUser = fallback['user'] is Map
        ? Map<String, dynamic>.from(fallback['user'] as Map)
        : <String, dynamic>{};
    final fallbackName = (fallback['name'] ??
            nestedUser['name'] ??
            fallback['username'] ??
            nestedUser['username'] ??
            '')
        .toString()
        .trim();
    return fallbackName.isEmpty ? null : fallbackName;
  }

  String? _directPeerId() {
    if (widget.conversation['type'] != 'direct') return null;
    final participants = widget.conversation['participants'];
    if (participants is! List) return null;
    final currentUserIds = <String>{
      app.user?['id']?.toString() ?? '',
      app.user?['_id']?.toString() ?? '',
    }..remove('');
    for (final participant in participants) {
      if (participant is! Map) continue;
      final nestedUser =
          participant['user'] is Map ? participant['user'] as Map : null;
      final rawId = participant['_id'] ??
          participant['id'] ??
          nestedUser?['_id'] ??
          nestedUser?['id'];
      if (rawId == null) continue;
      final id = rawId.toString();
      if (id.isNotEmpty && !currentUserIds.contains(id)) return id;
    }
    return null;
  }

  void _syncPresence() {
    if (!mounted) return;
    final peerId = _directPeerId();
    final shouldBeOnline =
        peerId != null && app.onlineUserIds.contains(peerId);
    final isOnline = peerId != null && onlineIds.contains(peerId);
    if (shouldBeOnline == isOnline) return;
    setState(() {
      onlineIds.clear();
      if (peerId != null && app.onlineUserIds.contains(peerId)) {
        onlineIds.add(peerId);
      }
    });
  }

  void _scrollToLatestMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messagesScrollController.hasClients) return;
      final position = _messagesScrollController.position;
      if (!position.hasContentDimensions) return;
      _messagesScrollController.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_isTyping) {
      socket?.emit('typing:stop', widget.conversation['_id']);
      _isTyping = false;
    }
  }

  void _handleTyping(String value) {
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_isTyping) {
      socket?.emit('typing:start', widget.conversation['_id']);
      _isTyping = true;
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1600), _stopTyping);
  }

  Future<void> load() async {
    try {
      final detail = await app.api
          .call('GET', '/api/conversations/${widget.conversation['_id']}');
      widget.conversation
          .addAll(Map<String, dynamic>.from(detail['conversation']));
      final result = await app.api.call(
          'GET', '/api/conversations/${widget.conversation['_id']}/messages');
      final fetched = List<dynamic>.from(result['messages'] ?? []);
      if (mounted) {
        setState(() {
          messages = mergeMessages(messages, fetched);
        });
        _scrollToLatestMessage();
        // Inspect recent text messages automatically; users do not need the manual-save menu.
        _scanRecentMessagesForMemory(fetched);
      }
      try {
        final paymentResult = await app.api.call('GET', '/api/payments');
        final conversationPayments =
            List<dynamic>.from(paymentResult['payments'] ?? [])
                .where((item) =>
                    item is Map &&
                    item['conversationId']?.toString() ==
                        widget.conversation['_id']?.toString())
                .toList();
        if (mounted) setState(() => payments = conversationPayments);
      } catch (_) {
        // Payment history is optional to loading a conversation and its messages.
      }
      for (final item in fetched) {
        if (item is Map &&
            item['senderId']?.toString() != app.user?['id']?.toString()) {
          markReceived(item['_id'].toString());
        }
      }
    } catch (error) {
      loadError = error.toString();
    }
    if (mounted) {
      setState(() => loading = false);
      _scrollToLatestMessage();
    }
  }

  void connect() {
    socket = io.io(
      app.api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': app.api.token})
          .disableAutoConnect()
          .build(),
    );
    socket!.connect();
    socket!.onConnect(
        (_) => socket!.emit('conversation:join', widget.conversation['_id']));
    socket!.on('typing:start', (data) {
      if (!mounted ||
          data is! Map ||
          data['userId']?.toString() == app.user?['id']?.toString()) {
        return;
      }
      final userId = data['userId']?.toString();
      if (userId == null || userId.isEmpty) return;
      _remoteTypingTimer?.cancel();
      setState(() => typingUser = userId);
      // Recover automatically if a stop event is lost during a reconnect.
      _remoteTypingTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && typingUser == userId) {
          setState(() => typingUser = null);
        }
      });
    });
    socket!.on('typing:stop', (data) {
      if (!mounted || data is! Map) return;
      if (typingUser == data['userId']?.toString()) {
        _remoteTypingTimer?.cancel();
        setState(() => typingUser = null);
      }
    });
    socket!.on('user:online', (data) {
      final peerId = _directPeerId();
      if (data is Map && mounted && peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() => onlineIds.add(peerId));
      }
    });
    socket!.on('user:offline', (data) {
      final peerId = _directPeerId();
      if (data is Map && mounted && peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() => onlineIds.remove(peerId));
      }
    });
    socket!.on('message:new', (data) {
      if (!mounted || data is! Map) return;
      if (data['conversationId']?.toString() ==
          widget.conversation['_id']?.toString()) {
        final incoming = Map<String, dynamic>.from(data);
        final id = incoming['_id']?.toString();
        if (id == null ||
            !messages
                .any((item) => item is Map && item['_id']?.toString() == id)) {
          setState(() => messages = mergeMessages(messages, [incoming]));
          _scrollToLatestMessage();
          // Detect meaningful information in new live messages.
          _detectMemoryForMessage(incoming);
        }
        if (id != null &&
            incoming['senderId']?.toString() != app.user?['id']?.toString()) {
          markReceived(id);
        }
      }
    });
    socket!.on('payment:updated', (data) {
      if (!mounted ||
          data is! Map ||
          data['conversationId']?.toString() !=
              widget.conversation['_id']?.toString()) {
        return;
      }
      final incoming = Map<String, dynamic>.from(data);
      final id = incoming['paymentId']?.toString();
      if (id == null) return;
      setState(() => payments = mergePayment(payments, incoming));
    });
    socket!.on('message:deleted', (data) {
      if (!mounted || data is! Map || data['conversationId']?.toString() != widget.conversation['_id']?.toString()) return;
      final index = messages.indexWhere((m) => m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index < 0) return;
      setState(() {
        final copy = Map<String, dynamic>.from(messages[index]);
        copy['deletedAt'] = data['deletedAt'] ?? DateTime.now().toIso8601String();
        copy['text'] = '';
        copy['mediaUrl'] = null;
        copy['messageType'] = 'text';
        copy['reactions'] = [];
        messages[index] = copy;
      });
    });
    socket!.on('message:expired', (data) {
      if (!mounted || data is! Map) return;
      final index = messages.indexWhere((m) =>
          m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index >= 0) {
        setState(() {
          final copy = Map<String, dynamic>.from(messages[index]);
          copy['expiredAt'] = DateTime.now().toIso8601String();
          copy['text'] = '';
          copy['mediaUrl'] = null;
          messages[index] = copy;
        });
      }
    });
    socket!.on(
        'message:delivered', (data) => updateMessageState(data, 'deliveredTo'));
    socket!.on('message:read', (data) => updateMessageState(data, 'readBy'));
  }

  void updateMessageState(dynamic data, String field) {
    if (!mounted || data is! Map) return;
    final index = messages.indexWhere((item) =>
        item is Map &&
        item['_id']?.toString() == data['messageId']?.toString());
    if (index < 0) return;
    setState(() {
      final updated = Map<String, dynamic>.from(messages[index]);
      final ids = List<dynamic>.from(updated[field] ?? []);
      if (!ids.any((id) => id.toString() == data['userId']?.toString())) {
        ids.add(data['userId']);
      }
      updated[field] = ids;
      messages[index] = updated;
    });
  }

  Future<void> markReceived(String id) async {
    try {
      await app.api.call('POST', '/api/messages/$id/delivered', {});
      await app.api.call('POST', '/api/messages/$id/read', {});
    } catch (_) {}
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    _stopTyping();
    setState(() => sending = true);
    try {
      final result = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'text': text,
        'expiryType': expiry,
        'expiresInSeconds': expiry == 'AFTER_TIME' ? 3600 : null,
        'replyTo': reply,
      });
      if (!mounted) return;
      final sent = Map<String, dynamic>.from(result['message']);
      final sentId = sent['_id']?.toString();
      setState(() {
        if (sentId == null ||
            !messages.any(
                (item) => item is Map && item['_id']?.toString() == sentId)) {
          messages = mergeMessages(messages, [sent]);
        }
        reply = null;
      });
      input.clear();
      _scrollToLatestMessage();
      // Sent messages can contain useful reminders or personal details too.
      _detectMemoryForMessage(sent);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> requestMpesa() async {
    final participants =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
    final me = app.user?['id']?.toString();
    final other = participants.whereType<Map>().firstWhere(
        (p) => p['_id']?.toString() != me,
        orElse: () => <String, dynamic>{});
    final payerId = other['_id']?.toString();
    if (payerId == null || payerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Conversation member details are unavailable.')));
      return;
    }
    final amount = TextEditingController();
    final payerPhone = TextEditingController(text: other['phone']?.toString() ?? '');
    final recipientPhone = TextEditingController(text: app.user?['phone']?.toString() ?? '');
    final description = TextEditingController();
    final form = GlobalKey<FormState>();
    final submit = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Request M-Pesa'),
              content: Form(
                  key: form,
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: amount,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Amount (KSh)'),
                          validator: (v) {
                            final value = int.tryParse(v ?? '');
                            return value == null || value < 1 || value > 150000
                                ? 'Enter KSh 1–150,000'
                                : null;
                          }),
                      TextFormField(
                          controller: payerPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Sender / Payer M-Pesa Number',
                              hintText: '0712345678 or 254712345678',
                              helperText: 'Defaults to the other participant’s registered number. You can edit it for this request.'),
                          validator: (v) => normalizeKenyanPhone(v ?? '') == null
                              ? 'Enter a valid Kenyan M-Pesa number'
                              : null),
                      TextFormField(
                          controller: recipientPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Recipient M-Pesa Number',
                              hintText: '0712345678 or 254712345678',
                              helperText: 'Defaults to your registered number. Editing affects this request only.'),
                          validator: (v) => normalizeKenyanPhone(v ?? '') == null
                              ? 'Enter a valid Kenyan M-Pesa number'
                              : null),
                      TextFormField(
                          controller: description,
                          maxLength: 80,
                          decoration:
                              const InputDecoration(labelText: 'Description'),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Enter a description'
                              : null),
                      const SizedBox(height: 8),
                      const Text(
                        'The selected payer number is the default for the STK prompt and can be changed before payment. STK Push payments settle to the configured business shortcode; this does not send money directly to a personal number.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ]),
                  )),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(dialog, true);
                      }
                    },
                    child: const Text('Request'))
              ],
            ));
    if (submit == true && mounted) {
      try {
        final response = await app.api.call('POST', '/api/payments', {
          'payerUserId': payerId,
          'conversationId': widget.conversation['_id'],
          'amount': int.parse(amount.text),
          'recipientPhone': normalizeKenyanPhone(recipientPhone.text)!,
          'payerPhone': normalizeKenyanPhone(payerPhone.text)!,
          'description': description.text.trim()
        });
        final payment = Map<String, dynamic>.from(response['payment']);
        if (mounted) setState(() => payments = mergePayment(payments, payment));
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }
    amount.dispose();
    payerPhone.dispose();
    recipientPhone.dispose();
    description.dispose();
  }

  Future<void> payPayment(Map<String, dynamic> payment) async {
    final payerPhone = TextEditingController(
        text: payment['payerPhone']?.toString() ?? payment['phone']?.toString() ?? app.user?['phone']?.toString() ?? '');
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Pay with M-Pesa'),
              content: Form(
                key: form,
                child: TextFormField(
                  controller: payerPhone,
                  autofocus: true,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Your M-Pesa phone number',
                    hintText: '0712345678 or 254712345678',
                    helperText: 'The STK prompt will be sent to this number.',
                  ),
                  validator: (v) => normalizeKenyanPhone(v ?? '') == null
                      ? 'Enter a valid Kenyan M-Pesa number'
                      : null,
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(dialog, true);
                      }
                    },
                    child: const Text('Continue')),
              ],
            ));
    if (accepted != true || !mounted) {
      payerPhone.dispose();
      return;
    }
    try {
      final result = await app.api.call(
          'POST', '/api/payments/${payment['paymentId']}/initiate', {
        'phone': normalizeKenyanPhone(payerPhone.text)!,
      });
      final updated = Map<String, dynamic>.from(result['payment']);
      if (mounted) {
        final i = payments.indexWhere(
            (p) => p is Map && p['paymentId'] == updated['paymentId']);
        setState(() {
          if (i >= 0) payments[i] = updated;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['mock'] == true
                ? 'Local demo only: no Safaricom prompt was sent. Configure live Daraja on the API service to send real prompts.'
                : 'Check ${normalizeKenyanPhone(payerPhone.text)} for the M-Pesa prompt. Enter your PIN only in the Safaricom prompt.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      payerPhone.dispose();
    }
  }

  Future<void> refreshPayment(Map<String, dynamic> payment) async {
    try {
      final result =
          await app.api.paymentStatus(payment['paymentId'].toString());
      final updated = Map<String, dynamic>.from(result['payment']);
      final i = payments.indexWhere(
          (p) => p is Map && p['paymentId'] == updated['paymentId']);
      if (mounted && i >= 0) setState(() => payments[i] = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> retryPayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/retry', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> closePayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api.call(
          'POST', '/api/payments/${payment['paymentId']}/close', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Closed for you. The other person can still see this request.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> reopenPayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api.call(
          'POST', '/api/payments/${payment['paymentId']}/reopen', {});
      if (mounted) {
        setState(() {
          payments = mergePayment(
              payments, Map<String, dynamic>.from(result['payment']));
          showClosedPayments = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Request reopened in this conversation.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> rejectPayment(Map<String, dynamic> payment) async {
    final isPayer =
        payment['payerId']?.toString() == app.user?['id']?.toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(isPayer ? 'Reject M-Pesa request?' : 'Withdraw M-Pesa request?'),
        content: const Text(
          'This cancels the request for both people and is only available before an M-Pesa prompt has started. If a prompt was already sent, close it for yourself and cancel it on your phone if it is still open.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep request')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(isPayer ? 'Reject request' : 'Withdraw request')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await app.api.call(
          'POST', '/api/payments/${payment['paymentId']}/reject', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isPayer
                ? 'Payment request rejected.'
                : 'Payment request withdrawn.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> searchMessages(String query) async {
    try {
      final result = await app.api.call('GET',
          '/api/conversations/${widget.conversation['_id']}/messages?q=${Uri.encodeQueryComponent(query)}');
      if (mounted) {
        setState(() => messages =
            mergeMessages([], List<dynamic>.from(result['messages'] ?? [])));
        _scrollToLatestMessage();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> sendImageLink() async {
    final source = await showModalBottomSheet<String>(
        context: context,
        builder: (sheet) => SafeArea(
              child: Wrap(children: [
                ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('Choose from device'),
                    onTap: () => Navigator.pop(sheet, 'device')),
                ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Share secure image URL'),
                    onTap: () => Navigator.pop(sheet, 'url')),
              ]),
            ));
    if (!mounted || source == null) return;
    try {
      Map<String, dynamic> uploadRequest;
      if (source == 'url') {
        final url = TextEditingController();
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
                    title: const Text('Share an image'),
                    content: TextField(
                        controller: url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                            labelText: 'Secure image URL',
                            hintText: 'https://…')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('Share'))
                    ]));
        if (accepted != true) {
          url.dispose();
          return;
        }
        uploadRequest = {'url': url.text.trim()};
        url.dispose();
      } else {
        final file = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) {
          throw Exception('Choose an image no larger than 10 MB');
        }
        final name = file.name.toLowerCase();
        final mimeType = name.endsWith('.png')
            ? 'image/png'
            : (name.endsWith('.webp') ? 'image/webp' : 'image/jpeg');
        uploadRequest = {'data': base64Encode(bytes), 'mimeType': mimeType};
      }
      final uploaded = await app.api.call('POST', '/api/media', uploadRequest);
      final sent = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'messageType': 'image',
        'mediaUrl': uploaded['mediaUrl'],
        'expiryType': expiry
      });
      if (mounted) {
        final message = Map<String, dynamic>.from(sent['message']);
        final id = message['_id']?.toString();
        setState(() {
          if (id == null ||
              !messages.any(
                  (item) => item is Map && item['_id']?.toString() == id)) {
            messages.add(message);
          }
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> groupOptions() async {
    final members =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
    final isAdmin = List<dynamic>.from(widget.conversation['admins'] ?? [])
        .any((id) => id.toString() == app.user?['id']?.toString());
    await showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
                child: Wrap(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      widget.conversation['description']
                                  ?.toString()
                                  .isNotEmpty ==
                              true
                          ? widget.conversation['description'].toString()
                          : '${members.length} members',
                      style: Theme.of(context).textTheme.titleMedium)),
              if (isAdmin)
                ListTile(
                    leading: const Icon(Icons.person_add_alt_1),
                    title: const Text('Add member'),
                    onTap: () async {
                      final email = TextEditingController();
                      try {
                        final chosen = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                                    title: const Text('Add group member'),
                                    content: TextField(
                                        controller: email,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        decoration: const InputDecoration(
                                            labelText: 'Member email')),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text('Add'))
                                    ]));
                        if (chosen != true) return;
                        final found = await app.api.call('GET',
                            '/api/users/search?q=${Uri.encodeQueryComponent(email.text.trim())}');
                        final users = List<dynamic>.from(found['users'] ?? []);
                        final emailValue = email.text.trim().toLowerCase();
                        final matches = users.where((user) =>
                            user is Map &&
                            user['email']?.toString().toLowerCase() ==
                                emailValue);
                        if (matches.isEmpty) {
                          throw Exception('No matching account found');
                        }
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/members',
                            {'userId': matches.first['_id']});
                        final d = await app.api.call('GET',
                            '/api/conversations/${widget.conversation['_id']}');
                        if (mounted) {
                          setState(() => widget.conversation.addAll(
                              Map<String, dynamic>.from(d['conversation'])));
                        }
                        if (sheet.mounted) Navigator.pop(sheet);
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      } finally {
                        email.dispose();
                      }
                    }),
              ...members.map((raw) {
                final person = Map<String, dynamic>.from(raw);
                final id = (person['_id'] ?? person['id']).toString();
                final admin =
                    List<dynamic>.from(widget.conversation['admins'] ?? [])
                        .any((item) => item.toString() == id);
                return ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(
                        '${person['name'] ?? 'Member'}${admin ? ' · admin' : ''}'),
                    subtitle: Text(person['email']?.toString() ?? ''),
                    trailing: isAdmin && id != app.user?['id']?.toString()
                        ? PopupMenuButton<String>(
                            onSelected: (action) async {
                              try {
                                if (action == 'remove') {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/members/$id');
                                } else if (admin) {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id');
                                } else {
                                  await app.api.call(
                                      'POST',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id',
                                      {});
                                }
                                final d = await app.api.call('GET',
                                    '/api/conversations/${widget.conversation['_id']}');
                                if (mounted) {
                                  setState(() => widget.conversation.addAll(
                                      Map<String, dynamic>.from(
                                          d['conversation'])));
                                }
                              } catch (error) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            },
                            itemBuilder: (_) => [
                                  PopupMenuItem(
                                      value: admin ? 'demote' : 'promote',
                                      child: Text(admin
                                          ? 'Remove admin'
                                          : 'Make admin')),
                                  const PopupMenuItem(
                                      value: 'remove',
                                      child: Text('Remove member'))
                                ])
                        : null);
              }),
              if (!isAdmin ||
                  List<dynamic>.from(widget.conversation['admins'] ?? [])
                          .length >
                      1)
                ListTile(
                    leading: const Icon(Icons.exit_to_app),
                    title: const Text('Leave group'),
                    onTap: () async {
                      try {
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/leave',
                            {});
                        if (mounted && sheet.mounted) {
                          Navigator.pop(sheet);
                          Navigator.pop(context);
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      }
                    })
            ])));
  }

  Future<void> downloadImage(String url) async {
    if (url.trim().isEmpty) return;
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Uint8List? bytes;
      var mime = 'image/jpeg';

      if (url.startsWith('data:image/')) {
        final comma = url.indexOf(',');
        if (comma < 0) throw const FormatException('Invalid image data.');
        mime = url.substring(5, comma).split(';').first.toLowerCase();
        bytes = Uint8List.fromList(
            base64Decode(url.substring(comma + 1)));
      } else {
        final uri = Uri.parse(url);
        if (uri.scheme != 'https' && uri.scheme != 'http') {
          throw Exception('This image URL cannot be downloaded safely.');
        }

        final path = uri.path.toLowerCase();
        final guessedExtension = path.endsWith('.png')
            ? 'png'
            : path.endsWith('.webp')
                ? 'webp'
                : path.endsWith('.gif')
                    ? 'gif'
                    : path.endsWith('.heic')
                        ? 'heic'
                        : 'jpg';

        // Browsers ignore the download attribute for many cross-origin URLs.
        // Cloudinary supports fl_attachment, which makes the original asset
        // respond with Content-Disposition: attachment so the browser saves it.
        if (kIsWeb) {
          var downloadUri = uri;
          if (uri.host.toLowerCase() == 'res.cloudinary.com' &&
              uri.path.contains('/image/upload/') &&
              !uri.path.contains('/image/upload/fl_attachment/')) {
            downloadUri = uri.replace(
              path: uri.path.replaceFirst(
                '/image/upload/',
                '/image/upload/fl_attachment/',
              ),
            );
          }

          await FileSaver.instance.downloadLink(
            link: LinkDetails(link: downloadUri.toString()),
            name: 'chatify_image_$timestamp.$guessedExtension',
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Image download requested. Check your browser downloads.'),
            ));
          }
          return;
        }

        final response = await http.get(uri).timeout(
              const Duration(seconds: 45),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('Image download failed (HTTP ${response.statusCode}).');
        }
        bytes = response.bodyBytes;
        mime = (response.headers['content-type'] ?? '').split(';').first.toLowerCase();
        if (!mime.startsWith('image/')) {
          mime = guessedExtension == 'png'
              ? 'image/png'
              : guessedExtension == 'webp'
                  ? 'image/webp'
                  : guessedExtension == 'gif'
                      ? 'image/gif'
                      : 'image/jpeg';
        }
      }

      final extension = mime.contains('png')
          ? 'png'
          : mime.contains('webp')
              ? 'webp'
              : mime.contains('gif')
                  ? 'gif'
                  : mime.contains('heic')
                      ? 'heic'
                      : mime.contains('svg')
                          ? 'svg'
                          : 'jpg';
      final saverMime = extension == 'png'
          ? MimeType.png
          : extension == 'webp'
              ? MimeType.webp
              : extension == 'gif'
                  ? MimeType.gif
                  : extension == 'heic'
                      ? MimeType.heic
                      : extension == 'svg'
                          ? MimeType.svg
                          : MimeType.jpeg;

      if (bytes.isEmpty) {
        throw Exception('The image file is empty.');
      }

      // Save the original response bytes directly. Never resize, recompress,
      // decode or re-encode the image during download.
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS) &&
          extension != 'svg') {
        await FileSaver.instance.saveToGallery(
          name: 'chatify_image_$timestamp',
          bytes: bytes,
          fileExtension: extension,
          mimeType: saverMime,
        );
      } else {
        await FileSaver.instance.saveFile(
          name: 'chatify_image_$timestamp',
          bytes: bytes,
          fileExtension: extension,
          mimeType: saverMime,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Image saved in its original quality.'),
        ));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not download image: $error')),
        );
      }
    }
  }

  Widget renderImage(String url) {
    Widget image;
    if (url.startsWith('data:image/')) {
      try {
        image = Image.memory(
          base64Decode(url.substring(url.indexOf(',') + 1)),
          width: 220,
          fit: BoxFit.contain,
        );
      } catch (_) {
        return const Text('Image unavailable');
      }
    } else {
      image = Image.network(
        url,
        width: 220,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Text('Image unavailable'),
      );
    }

    return Stack(
      alignment: Alignment.topRight,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: image,
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: const Color(0xE6172033),
            borderRadius: BorderRadius.circular(24),
            child: IconButton(
              tooltip: 'Download original image',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 38, height: 38),
              padding: EdgeInsets.zero,
              color: Colors.white,
              icon: const Icon(Icons.download_rounded, size: 20),
              onPressed: () => downloadImage(url),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    app.removeListener(_syncPresence);
    _typingTimer?.cancel();
    _remoteTypingTimer?.cancel();
    if (_isTyping) socket?.emit('typing:stop', widget.conversation['_id']);
    socket?.dispose();
    _messagesScrollController.dispose();
    input.dispose();
    searchInput.dispose();
    super.dispose();
  }

  // Scan newest-first and stop when a meaningful suggestion is found.
  Future<void> _scanRecentMessagesForMemory(List<dynamic> sourceMessages) async {
    final recent = sourceMessages.whereType<Map>().toList().reversed.take(12);
    for (final raw in recent) {
      if (await _detectMemoryForMessage(Map<String, dynamic>.from(raw))) return;
    }
  }

  Future<bool> _detectMemoryForMessage(Map<String, dynamic> message) async {
    if (message['messageType'] != 'text' ||
        message['deletedAt'] != null ||
        message['expiredAt'] != null ||
        message['text'] is! String) {
      return false;
    }
    final text = (message['text'] as String).trim();
    final id = message['_id']?.toString();
    if (text.isEmpty || id == null || id.isEmpty ||
        _checkedMemoryMessageIds.contains(id) ||
        _dismissedMemoryMessageIds.contains(id) ||
        _savedMemoryMessageIds.contains(id)) {
      return false;
    }
    _checkedMemoryMessageIds.add(id);
    try {
      final result = await app.api.call(
          'POST', '/api/memories/extract', {'text': text});
      final candidates = List<dynamic>.from(result['candidates'] ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) =>
              item['title'] is String &&
              (item['title'] as String).trim().isNotEmpty &&
              item['description'] is String &&
              (item['description'] as String).trim().isNotEmpty)
          .toList();
      if (!mounted || candidates.isEmpty) return false;
      // The user must approve the suggestion; detection itself never saves data.
      setState(() {
        memorySuggestions = candidates;
        memorySuggestionSourceId = id;
      });
      return true;
    } catch (_) {
      // Memory detection is optional and must never interrupt normal messaging.
      return false;
    }
  }

  void _dismissMemorySuggestions() {
    final id = memorySuggestionSourceId;
    if (id != null) _dismissedMemoryMessageIds.add(id);
    if (!mounted) return;
    setState(() {
      memorySuggestions = [];
      memorySuggestionSourceId = null;
    });
  }

  Future<void> _saveMemorySuggestion(Map<String, dynamic> candidate) async {
    final sourceId = memorySuggestionSourceId;
    if (sourceId == null || savingMemorySuggestion) return;
    setState(() => savingMemorySuggestion = true);
    try {
      await app.api.call('POST', '/api/memories', {
        ...candidate,
        'conversationId': widget.conversation['_id'],
        'sourceMessageId': sourceId,
      });
      if (!mounted) return;
      _savedMemoryMessageIds.add(sourceId);
      setState(() {
        memorySuggestions.remove(candidate);
        if (memorySuggestions.isEmpty) memorySuggestionSourceId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory saved to your Memory Cards.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save memory: $error')));
      }
    } finally {
      if (mounted) setState(() => savingMemorySuggestion = false);
    }
  }

  Future<void> extractMemory() async {
    try {
      final eligibleSources = messages
          .whereType<Map>()
          .where((item) =>
              item['expiredAt'] == null &&
              item['messageType'] == 'text' &&
              item['text'] is String &&
              (item['text'] as String).trim().isNotEmpty)
          .toList();
      final source = input.text.trim().isNotEmpty || eligibleSources.isEmpty
          ? null
          : eligibleSources.last;
      final sourceText = input.text.trim().isNotEmpty
          ? input.text.trim()
          : source?['text']?.toString() ?? '';
      if (sourceText.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Send a message before extracting a memory.')));
        return;
      }
      final result = await app.api
          .call('POST', '/api/memories/extract', {'text': sourceText});
      final candidates = List<dynamic>.from(result['candidates'] ?? []);
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No memory candidate found.')));
        return;
      }
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Save a memory'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: candidates.map((raw) {
                final item = Map<String, dynamic>.from(raw);
                return ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(item['title']?.toString() ?? 'Memory'),
                  subtitle: Text(item['description']?.toString() ?? ''),
                  onTap: () => Navigator.pop(dialog, item),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel'))
          ],
        ),
      );
      if (selected == null) return;
      await app.api.call('POST', '/api/memories', {
        ...selected,
        'conversationId': widget.conversation['_id'],
        if (source != null && source['_id'] != null)
          'sourceMessageId': source['_id'],
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Memory saved')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> reactTo(String messageId, String emoji) async {
    try {
      final result = await app.api
          .call('POST', '/api/messages/$messageId/reactions', {'emoji': emoji});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages.indexWhere(
          (item) => item is Map && item['_id']?.toString() == messageId);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> deleteMessage(Map<String, dynamic> message) async {
    final id = message['_id']?.toString();
    if (id == null || id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text('This removes the message for everyone in the conversation. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Delete for everyone')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await app.api.call('DELETE', '/api/messages/$id', {});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages.indexWhere((item) => item is Map && item['_id']?.toString() == id);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message deleted for everyone.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> showMessageActions(Map<String, dynamic> message) async {
    final mine = message['senderId']?.toString() == app.user?['id']?.toString();
    final deleted = message['deletedAt'] != null || message['expiredAt'] != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Wrap(
          children: [
            if (!deleted) ...[
              ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(sheet, 'reply')),
              ListTile(leading: const Text('❤️', style: TextStyle(fontSize: 22)), title: const Text('React with ❤️'), onTap: () => Navigator.pop(sheet, '❤️')),
              ListTile(leading: const Text('👍', style: TextStyle(fontSize: 22)), title: const Text('React with 👍'), onTap: () => Navigator.pop(sheet, '👍')),
              ListTile(leading: const Text('😂', style: TextStyle(fontSize: 22)), title: const Text('React with 😂'), onTap: () => Navigator.pop(sheet, '😂')),
            ],
            if (mine && !deleted) ListTile(leading: const Icon(Icons.delete_outline, color: Colors.red), title: const Text('Delete for everyone'), onTap: () => Navigator.pop(sheet, 'delete')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'reply') {
      setState(() => reply = message['_id']?.toString());
    } else if (action == 'delete') {
      await deleteMessage(message);
    } else if (message['_id'] != null) {
      await reactTo(message['_id'].toString(), action);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Direct chats show the other participant's real name above their presence status.
    // Group chats keep using the configured group title.
    final title = widget.conversation['type'] == 'group'
        ? (widget.conversation['title'] ?? 'Group').toString()
        : (_directPeerName() ?? 'Chat');
    final currentUserId = app.user?['id']?.toString();
    final closedPaymentCount = payments.where((item) {
      if (item is! Map) return false;
      return List<dynamic>.from(item['dismissedBy'] ?? [])
          .any((id) => id.toString() == currentUserId);
    }).length;
    final visiblePayments = payments.where((item) {
      if (item is! Map) return false;
      final dismissedBy = List<dynamic>.from(item['dismissedBy'] ?? []);
      final isClosedForMe =
          dismissedBy.any((id) => id.toString() == currentUserId);
      return showClosedPayments || !isClosedForMe;
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(
                controller: searchInput,
                autofocus: true,
                onChanged: searchMessages,
                decoration: const InputDecoration(
                    hintText: 'Search this chat', border: InputBorder.none))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                    Text(title),
                    if (widget.conversation['type'] == 'direct')
                      Text(onlineIds.isNotEmpty ? 'Online' : 'Offline',
                          style: Theme.of(context).textTheme.labelSmall)
                  ]),
        actions: [
          if (widget.conversation['type'] == 'direct')
            IconButton(
                onPressed: requestMpesa,
                tooltip: 'Request M-Pesa',
                icon: const Icon(Icons.payments_outlined)),
          IconButton(
              onPressed: () {
                setState(() {
                  searching = !searching;
                  if (!searching) {
                    searchInput.clear();
                    load();
                  }
                });
              },
              tooltip: 'Search messages',
              icon: Icon(searching ? Icons.close : Icons.search)),
          if (widget.conversation['type'] == 'group')
            IconButton(
                onPressed: groupOptions,
                tooltip: 'Group details',
                icon: const Icon(Icons.group_outlined)),
          IconButton(
              onPressed: extractMemory,
              tooltip: 'Save memory',
              icon: const Icon(Icons.auto_awesome)),
        ],
      ),
      body: Column(children: [
        if (closedPaymentCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => showClosedPayments = !showClosedPayments),
              icon: Icon(showClosedPayments
                  ? Icons.visibility_off_outlined
                  : Icons.history),
              label: Text(showClosedPayments
                  ? 'Hide closed requests'
                  : 'Show closed requests ($closedPaymentCount)'),
            ),
          ),
        if (visiblePayments.isNotEmpty)
          SizedBox(
              height: visiblePayments.length > 2 ? 220 : null,
              child: ListView.builder(
                  shrinkWrap: visiblePayments.length <= 2,
                  itemCount: visiblePayments.length,
                  itemBuilder: (_, index) {
                    final payment =
                        Map<String, dynamic>.from(visiblePayments[index]);
                    final isPayer =
                        payment['payerId']?.toString() == currentUserId;
                    final isClosedForMe =
                        List<dynamic>.from(payment['dismissedBy'] ?? [])
                            .any((id) => id.toString() == currentUserId);
                    return PaymentCard(
                        payment: payment,
                        currentUserId: currentUserId,
                        onPay: isClosedForMe ? null : () => payPayment(payment),
                        onRetry:
                            isClosedForMe ? null : () => retryPayment(payment),
                        onClose:
                            isClosedForMe ? null : () => closePayment(payment),
                        onReject:
                            isClosedForMe ? null : () => rejectPayment(payment),
                        onReopen:
                            isClosedForMe ? () => reopenPayment(payment) : null,
                        rejectLabel:
                            isPayer ? 'Reject request' : 'Withdraw request',
                        onRefresh: () => refreshPayment(payment));
                  })),
        if (widget.conversation['type'] == 'direct')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: requestMpesa,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Request M-Pesa'),
              ),
            ),
          ),
        if (typingUser != null)
          const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Someone is typing…')),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : loadError != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: load, child: const Text('Retry'))
                    ]))
                  : messages.isEmpty
                      ? const Empty(
                          icon: Icons.chat_bubble_outline,
                          title: 'Start the conversation',
                          subtitle: 'Send the first message.')
                      : ListView.builder(
                          controller: _messagesScrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: messages.length,
                          itemBuilder: (_, i) {
                            final message =
                                Map<String, dynamic>.from(messages[i]);
                            final mine = message['senderId']?.toString() ==
                                app.user?['id']?.toString();
                            final text = message['deletedAt'] != null
                                ? 'This message was deleted.'
                                : message['expiredAt'] != null
                                    ? 'This message has expired.'
                                    : (message['text'] ?? '[media]').toString();
                            return GestureDetector(
                              onLongPress: () => showMessageActions(message),
                              child: Row(
                                mainAxisAlignment: mine
                                    ? MainAxisAlignment.end
                                    : MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: Container(
                                      // Keep bubbles content-sized and aligned like a
                                      // modern messenger; long messages wrap instead of
                                      // stretching across the phone screen.
                                      constraints: BoxConstraints(
                                        maxWidth:
                                            (MediaQuery.sizeOf(context).width * 0.62)
                                                .clamp(180.0, 520.0)
                                                .toDouble(),
                                      ),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 13, vertical: 10),
                                      decoration: BoxDecoration(
                                        // Strongly distinct, high-contrast colors make
                                        // sent and received messages easy to scan.
                                        color: mine
                                            ? const Color(0xFF4F46E5)
                                            : const Color(0xFFFFFFFF),
                                        borderRadius: BorderRadius.only(
                                          topLeft: const Radius.circular(18),
                                          topRight: const Radius.circular(18),
                                          bottomLeft: Radius.circular(mine ? 18 : 5),
                                          bottomRight: Radius.circular(mine ? 5 : 18),
                                        ),
                                        border: Border.all(
                                          color: mine
                                              ? const Color(0xFF4338CA)
                                              : const Color(0xFFD9DFEA),
                                        ),
                                      ),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(
                                          color: mine
                                              ? Colors.white
                                              : const Color(0xFF253047),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            // A reply keeps only the original message ID in storage.
                                            // Resolve it against the current conversation so deleted,
                                            // expired, or unavailable originals never break rendering.
                                            if (message['replyTo'] != null)
                                              Builder(builder: (context) {
                                                final original = findReplyTarget(messages, message['replyTo']);
                                                // A non-null empty map keeps preview rendering null-safe
                                                // while the unavailable flag preserves deleted-message semantics.
                                                final originalMap = original ?? <String, dynamic>{};
                                                final unavailable = original == null ||
                                                    originalMap['deletedAt'] != null ||
                                                    originalMap['expiredAt'] != null;
                                                final originalSender = originalMap['senderId']?.toString() ==
                                                        app.user?['id']?.toString()
                                                    ? 'You'
                                                    : 'Message';
                                                final preview = unavailable
                                                    ? 'Original message unavailable'
                                                    : (originalMap['text'] ?? '[media]').toString();
                                                return Container(
                                                  width: double.infinity,
                                                  margin: const EdgeInsets.only(bottom: 7),
                                                  padding: const EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color: mine ? const Color(0x33404040) : const Color(0xFFF0EFFF),
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border(left: BorderSide(
                                                      color: mine ? Colors.white70 : const Color(0xFF4F46E5),
                                                      width: 3,
                                                    )),
                                                  ),
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text('Replying to $originalSender',
                                                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11,
                                                              color: mine ? Colors.white : const Color(0xFF4F46E5))),
                                                      Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis,
                                                          style: TextStyle(fontSize: 12,
                                                              color: mine ? Colors.white : const Color(0xFF39445A))),
                                                    ],
                                                  ),
                                                );
                                              }),
                                            if (mine &&
                                                message['deletedAt'] == null &&
                                                message['expiredAt'] == null)
                                              Align(
                                                widthFactor: 1,
                                                alignment: Alignment.centerRight,
                                                child: PopupMenuButton<String>(
                                                  tooltip: 'Message options',
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  iconSize: 20,
                                                  icon: Icon(
                                                    Icons.more_horiz,
                                                    color: mine
                                                        ? Colors.white
                                                        : const Color(0xFF536078),
                                                  ),
                                                  onSelected: (action) {
                                                    if (action == 'delete') {
                                                      deleteMessage(message);
                                                    }
                                                  },
                                                  itemBuilder: (_) => const [
                                                    PopupMenuItem<String>(
                                                      value: 'delete',
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            Icons.delete_outline,
                                                            color: Color(0xFFDC2626),
                                                            size: 20,
                                                          ),
                                                          SizedBox(width: 10),
                                                          Text('Delete for everyone'),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            if (message['deletedAt'] == null &&
                                                message['expiredAt'] == null &&
                                                message['messageType'] == 'image' &&
                                                message['mediaUrl'] != null)
                                              renderImage(
                                                  message['mediaUrl'].toString())
                                            else
                                              Text(text),
                                            if (message['deletedAt'] == null &&
                                                message['reactions'] is List &&
                                                (message['reactions'] as List)
                                                    .isNotEmpty)
                                              Text((message['reactions'] as List)
                                                  .map((r) => r['emoji'])
                                                  .join(' ')),
                                            if (mine &&
                                                message['deliveredTo'] is List &&
                                                (message['deliveredTo'] as List)
                                                        .length >
                                                    1)
                                              Text(
                                                  message['readBy'] is List &&
                                                          (message['readBy']
                                                                      as List)
                                                                  .length >
                                                              1
                                                      ? 'Read'
                                                      : 'Delivered',
                                                  style:
                                                      const TextStyle(fontSize: 10))
                                          ]),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
        if (memorySuggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Chatify noticed something worth remembering',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Not now',
                          visualDensity: VisualDensity.compact,
                          onPressed: savingMemorySuggestion ? null : _dismissMemorySuggestions,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    for (final suggestion in memorySuggestions)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(suggestion['title']?.toString() ?? 'Memory',
                                      style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text(suggestion['description']?.toString() ?? ''),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: savingMemorySuggestion
                                  ? null
                                  : () => _saveMemorySuggestion(suggestion),
                              child: savingMemorySuggestion
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('Save'),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: savingMemorySuggestion ? null : _dismissMemorySuggestions,
                        child: const Text('Not now'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Keep the selected original visible while composing so users can verify
        // exactly which message their reply will reference, and allow cancellation.
        if (reply != null)
          Builder(builder: (context) {
            final original = findReplyTarget(messages, reply);
            // The fallback map lets the composer preview safely handle a missing or expired target.
            final originalMap = original ?? <String, dynamic>{};
            final originalDeleted = original == null ||
                originalMap['deletedAt'] != null || originalMap['expiredAt'] != null;
            final originalSender = originalMap['senderId']?.toString() ==
                    app.user?['id']?.toString()
                ? 'You'
                : 'Message';
            final originalText = originalDeleted
                ? 'Original message unavailable'
                : (originalMap['text'] ?? '[media]').toString();
            return Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF0EFFF),
                border: const Border(left: BorderSide(color: Color(0xFF4F46E5), width: 3)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.reply, color: Color(0xFF4F46E5), size: 19),
                const SizedBox(width: 8),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Replying to $originalSender',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF4F46E5))),
                    Text(originalText, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF39445A))),
                  ],
                )),
                IconButton(
                  tooltip: 'Cancel reply',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => reply = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
            );
          }),
        SafeArea(
            child: Row(children: [
          IconButton(
              onPressed: sendImageLink,
              tooltip: 'Share image URL',
              icon: const Icon(Icons.image_outlined)),
          PopupMenuButton<String>(
            onSelected: (value) => setState(() => expiry = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'NONE', child: Text('Permanent')),
              PopupMenuItem(value: 'AFTER_READ', child: Text('After read')),
              PopupMenuItem(value: 'AFTER_TIME', child: Text('After 1 hour')),
              PopupMenuItem(value: 'AFTER_REPLY', child: Text('After reply')),
            ],
          ),
          Expanded(
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;

                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    if (!sending) send();
                    return KeyEventResult.handled;
                  }

                  // When the composer is empty, use the arrow keys to browse
                  // the conversation instead of moving an invisible caret.
                  if (input.text.isEmpty &&
                      _messagesScrollController.hasClients &&
                      (key == LogicalKeyboardKey.arrowUp ||
                          key == LogicalKeyboardKey.arrowDown)) {
                    final position = _messagesScrollController.position;
                    final distance = position.viewportDimension * 0.7;
                    final target = (position.pixels +
                            (key == LogicalKeyboardKey.arrowUp
                                ? -distance
                                : distance))
                        .clamp(
                          position.minScrollExtent,
                          position.maxScrollExtent,
                        )
                        .toDouble();
                    _messagesScrollController.animateTo(
                      target,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                    );
                    return KeyEventResult.handled;
                  }

                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (!sending) send();
                  },
                  onChanged: _handleTyping,
                  decoration: const InputDecoration(
                    hintText: 'Write a message…',
                    border: InputBorder.none,
                  ),
                ),
              )),
          IconButton(
              onPressed: sending ? null : send,
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send)),
        ])),
      ]),
    );
  }
}

// Screen for viewing and editing the signed-in user's profile and preferences.
class Profile extends StatefulWidget {
  const Profile({super.key});
  @override
  State<Profile> createState() => _ProfileState();
}

// Loads profile data and submits profile/privacy/notification preference changes.
class _ProfileState extends State<Profile> {
  late TextEditingController name, phone;
  bool lastSeen = true,
      receipts = true,
      messages = true,
      mentions = true,
      memories = true;
  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user ?? {};
    name = TextEditingController(text: u['name']?.toString() ?? '');
    phone = TextEditingController(text: u['phone']?.toString() ?? '');
    final p = Map<String, dynamic>.from(u['privacy'] ?? {}),
        n = Map<String, dynamic>.from(u['notificationPreferences'] ?? {});
    lastSeen = p['lastSeen'] ?? true;
    receipts = p['readReceipts'] ?? true;
    messages = n['messages'] ?? true;
    mentions = n['mentions'] ?? true;
    memories = n['memories'] ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final api = context.read<AppState>().api;
    try {
      final d = await api.call('PATCH', '/api/users/me', {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'privacy': {'lastSeen': lastSeen, 'readReceipts': receipts},
        'notificationPreferences': {
          'messages': messages,
          'mentions': mentions,
          'memories': memories
        },
      });
      if (!mounted) return;
      context.read<AppState>().user = Map<String, dynamic>.from(d['user']);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> saveDefaultPhone() async {
    final normalized = normalizeKenyanPhone(phone.text);
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid Kenyan M-Pesa number, e.g. 0712345678')));
      return;
    }
    try {
      final d = await context
          .read<AppState>()
          .api
          .call('PATCH', '/api/users/me', {'phone': normalized});
      if (!mounted) return;
      final app = context.read<AppState>();
      app.user = Map<String, dynamic>.from(d['user']);
      phone.text = normalized;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Default M-Pesa number saved. Payment requests will use it automatically.')));
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    try {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Change password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: current,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Current password')),
                    TextField(
                        controller: next,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await context.read<AppState>().api.call(
                                'POST', '/api/auth/change-password', {
                              'currentPassword': current.text,
                              'newPassword': next.text
                            });
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Password changed')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Update'))
                  ]));
    } finally {
      current.dispose();
      next.dispose();
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(18), children: [
        TextField(
            controller: name,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        const Text('Default M-Pesa number',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('Set this for your existing account. Chatify will prefill it when you send or receive payment requests. You can still change either number on an individual request.'),
        const SizedBox(height: 10),
        TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: 'M-Pesa phone number',
                hintText: '0712345678 or 254712345678',
                helperText: (context.watch<AppState>().user?['phone']?.toString().isNotEmpty ?? false)
                    ? 'Saved default: ${context.watch<AppState>().user?['phone']}'
                    : 'No default saved yet — add your number below.',
                border: const OutlineInputBorder())),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: saveDefaultPhone,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Save default M-Pesa number')),
        const SizedBox(height: 18),
        const Text('Privacy',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SwitchListTile(
            value: lastSeen,
            onChanged: (v) => setState(() => lastSeen = v),
            title: const Text('Show last seen')),
        SwitchListTile(
            value: receipts,
            onChanged: (v) => setState(() => receipts = v),
            title: const Text('Read receipts')),
        const Text('Notifications',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SwitchListTile(
            value: messages,
            onChanged: (v) => setState(() => messages = v),
            title: const Text('New messages')),
        SwitchListTile(
            value: mentions,
            onChanged: (v) => setState(() => mentions = v),
            title: const Text('Mentions')),
        SwitchListTile(
            value: memories,
            onChanged: (v) => setState(() => memories = v),
            title: const Text('Memory suggestions')),
        FilledButton(onPressed: save, child: const Text('Save changes')),
        TextButton(
            onPressed: changePassword, child: const Text('Change password')),
        TextButton(
            onPressed: () => context.read<AppState>().logout(),
            child: const Text('Sign out'))
      ]);
}


/// Customer-facing storefront. Product prices are display-only until the server creates
/// an order from its own catalogue records; successful payment is confirmed by Daraja callback.
class StorefrontPage extends StatefulWidget {
  final String slug;
  const StorefrontPage({super.key, required this.slug});
  @override
  State<StorefrontPage> createState() => _StorefrontPageState();
}

class _StorefrontPageState extends State<StorefrontPage> {
  Map<String, dynamic> storefront = {};
  List<dynamic> products = [];
  final Map<String, int> cart = {};
  final phone = TextEditingController();
  bool loading = true, checkingOut = false;
  String? error, paymentId, notice;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    phone.text = app.user?['phone']?.toString() ?? '';
    loadStore();
  }

  @override
  void dispose() {
    phone.dispose();
    super.dispose();
  }

  Future<void> loadStore() async {
    setState(() { loading = true; error = null; });
    try {
      final result = await app.api.call('GET', '/api/storefront/${Uri.encodeComponent(widget.slug)}');
      if (!mounted) return;
      setState(() {
        storefront = Map<String, dynamic>.from(result['storefront'] ?? {});
        products = List<dynamic>.from(result['items'] ?? []);
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  double get total => products.whereType<Map>().fold<double>(0, (sum, raw) {
    final item = Map<String, dynamic>.from(raw);
    return sum + (double.tryParse(item['price']?.toString() ?? '') ?? 0) *
        (cart[item['_id']?.toString()] ?? 0);
  });

  void addProduct(Map<String, dynamic> item) {
    final id = item['_id']?.toString();
    if (id == null) return;
    final current = cart[id] ?? 0;
    final stock = int.tryParse(item['stock']?.toString() ?? '') ?? 0;
    if (stock > 0 && current >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have selected all available stock for this product.')));
      return;
    }
    setState(() => cart[id] = current + 1);
  }

  Future<void> showProduct(Map<String, dynamic> item) async {
    final id = item['_id']?.toString() ?? '';
    final image = (item['images'] is List && (item['images'] as List).isNotEmpty)
        ? (item['images'] as List).first.toString() : '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item['name']?.toString() ?? 'Product'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image.startsWith('https://')) ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(image, height: 170, width: double.infinity, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
            const SizedBox(height: 8),
            Text('KSh ${item['price'] ?? '—'}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(item['description']?.toString() ?? 'No product description yet.'),
            if ((item['category']?.toString() ?? '').isNotEmpty) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Chip(label: Text(item['category'].toString())),
            ),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () { Navigator.pop(dialogContext); addProduct(item); },
            icon: const Icon(Icons.add_shopping_cart),
            label: Text(cart[id] == null ? 'Add to cart' : 'Add another'),
          ),
        ],
      ),
    );
  }

  Future<void> checkout() async {
    if (cart.isEmpty || checkingOut) return;
    if (app.user == null) {
      final signIn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sign in to pay'),
          content: const Text('You can browse products without an account. Sign in or create an account to place an order and receive the secure M-Pesa payment prompt.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
          ],
        ),
      );
      if (signIn == true && mounted) app.openAuth(register: true);
      return;
    }
    if (normalizeKenyanPhone(phone.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid Kenyan M-Pesa phone number.')));
      return;
    }
    setState(() { checkingOut = true; notice = null; error = null; });
    try {
      final result = await app.api.call('POST', '/api/storefront/${Uri.encodeComponent(widget.slug)}/checkout', {
        'phone': phone.text.trim(),
        'items': cart.entries.map((entry) => {'itemId': entry.key, 'quantity': entry.value}).toList(),
      });
      final payment = Map<String, dynamic>.from(result['payment'] ?? {});
      final id = payment['paymentId']?.toString();
      if (id == null || id.isEmpty) throw const FormatException('Order was created but no payment reference was returned.');
      if (mounted) setState(() { paymentId = id; notice = 'Order created. Requesting M-Pesa payment prompt…'; });
      final initiated = await app.api.call('POST', '/api/payments/${Uri.encodeComponent(id)}/initiate', {'phone': phone.text.trim()});
      if (!mounted) return;
      final isMock = initiated['mock'] == true;
      setState(() {
        notice = isMock
            ? 'Order created, but the server is in demo M-Pesa mode. No real Safaricom prompt was sent.'
            : 'Check your phone and enter your M-Pesa PIN to approve the payment. Then refresh payment status below.';
        cart.clear();
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => checkingOut = false);
    }
  }

  Future<void> refreshPayment() async {
    final id = paymentId;
    if (id == null) return;
    try {
      final result = await app.api.call('GET', '/api/payments/${Uri.encodeComponent(id)}');
      final payment = Map<String, dynamic>.from(result['payment'] ?? {});
      final status = payment['status']?.toString() ?? 'PENDING';
      if (mounted) {
        setState(() => notice = status == 'SUCCESS'
            ? 'Payment confirmed. Thank you for your order!'
            : status == 'PENDING'
                ? 'Payment is still pending. Complete the M-Pesa prompt on your phone, then refresh.'
                : 'Payment status: $status. You can contact the store if you need help.');
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (error != null && storefront.isEmpty) {
      return Scaffold(appBar: AppBar(title: const Text('Storefront')), body: Center(child: Padding(
        padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storefront_outlined, size: 48),
          const SizedBox(height: 12),
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: loadStore, child: const Text('Retry')),
        ]),
      )));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(storefront['name']?.toString() ?? 'Storefront'),
        actions: [IconButton(tooltip: 'Refresh products', onPressed: loadStore, icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: loadStore,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(colors: [Color(0xFF292C57), Color(0xFF5548E8)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.storefront_rounded, color: Colors.white, size: 30),
                const SizedBox(height: 10),
                Text(storefront['name']?.toString() ?? 'Shop', style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text(storefront['description']?.toString() ?? 'Browse products, add what you need to your cart, and pay securely with M-Pesa.', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 10),
                const Text('Secure checkout · M-Pesa', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                if ((storefront['sellerMpesaPhone']?.toString() ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Seller M-Pesa: ${storefront['sellerMpesaPhone']}', style: const TextStyle(color: Colors.white70)),
                ],
              ]),
            ),
            const SizedBox(height: 16),
            Text('Products', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (products.isEmpty) const Padding(
              padding: EdgeInsets.all(24),
              child: Text('This store has no active products yet.', textAlign: TextAlign.center),
            ),
            ...products.whereType<Map>().map((raw) {
              final item = Map<String, dynamic>.from(raw);
              final id = item['_id']?.toString() ?? '';
              final image = (item['images'] is List && (item['images'] as List).isNotEmpty) ? (item['images'] as List).first.toString() : '';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showProduct(item),
                  child: Row(children: [
                    if (image.startsWith('https://')) SizedBox(width: 100, height: 110, child: Image.network(image, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_outlined)))
                    else Container(width: 100, height: 110, color: const Color(0xFFF0F2F8), child: const Icon(Icons.inventory_2_outlined, size: 34)),
                    Expanded(child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(item['name']?.toString() ?? 'Product', style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(item['description']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 6),
                        Text('KSh ${item['price'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF4F46E5))),
                        const SizedBox(height: 5),
                        Row(children: [
                          Expanded(child: Text((cart[id] ?? 0) > 0 ? 'In cart: ${cart[id]}' : 'Tap to view details', style: const TextStyle(fontSize: 11))),
                          IconButton(onPressed: () => addProduct(item), icon: const Icon(Icons.add_circle_outline), tooltip: 'Add to cart'),
                        ]),
                      ]),
                    )),
                  ]),
                ),
              );
            }),
            if (cart.isNotEmpty) Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Your cart · ${cart.values.fold<int>(0, (sum, value) => sum + value)} item(s)', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  ...cart.entries.map((entry) {
                    final item = products.whereType<Map>().firstWhere((p) => p['_id']?.toString() == entry.key, orElse: () => <String, dynamic>{});
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item['name']?.toString() ?? 'Product'),
                      subtitle: Text('${entry.value} × KSh ${item['price'] ?? ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(onPressed: () => setState(() { if (entry.value <= 1) { cart.remove(entry.key); } else { cart[entry.key] = entry.value - 1; } }), icon: const Icon(Icons.remove_circle_outline)),
                        IconButton(onPressed: () { final product = products.whereType<Map>().firstWhere((p) => p['_id']?.toString() == entry.key, orElse: () => <String, dynamic>{}); if (product.isNotEmpty) addProduct(Map<String, dynamic>.from(product)); }, icon: const Icon(Icons.add_circle_outline)),
                      ]),
                    );
                  }),
                  const Divider(),
                  Row(children: [
                    const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800))),
                    Text('KSh ${total.toStringAsFixed(0)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'M-Pesa phone number',
                      hintText: '0712345678',
                      prefixIcon: Icon(Icons.phone_android),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(width: double.infinity, child: FilledButton.icon(
                    onPressed: checkingOut ? null : checkout,
                    icon: checkingOut ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.lock_outline),
                    label: Text(checkingOut ? 'Starting secure checkout…' : 'Checkout with M-Pesa'),
                  )),
                ]),
              ),
            ),
            if (notice != null) Card(color: const Color(0xFFE9F8F2), child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(notice!, style: const TextStyle(color: Color(0xFF155E48))),
                if (paymentId != null) ...[
                  const SizedBox(height: 8),
                  SelectableText('Payment reference: $paymentId'),
                  Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: refreshPayment, icon: const Icon(Icons.refresh), label: const Text('Refresh payment status'))),
                ],
              ]),
            )),
            if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ],
        ),
      ),
    );
  }
}

/// Business operations workspace: lightweight mobile entry points to the authenticated
/// organization, catalogue, customer CRM, sales documents and follow-up task APIs.
class BusinessHub extends StatefulWidget {
  const BusinessHub({super.key});
  @override
  State<BusinessHub> createState() => _BusinessHubState();
}

class _BusinessHubState extends State<BusinessHub> {
  Map<String, dynamic>? organization;
  Map<String, dynamic> dashboard = {};
  List<dynamic> organizations = [], catalog = [], customers = [], documents = [], tasks = [];
  bool loading = true, saving = false;
  int pendingOfflineCount = 0;
  List<String> syncConflicts = [];
  String? error;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    loadOrganizations();
  }

  Future<void> loadOrganizations() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final result = await app.api.call('GET', '/api/business/organizations');
      organizations = List<dynamic>.from(result['organizations'] ?? []);
      if (organizations.isNotEmpty) {
        final currentId = organization?['_id']?.toString();
        organization = organizations.firstWhere(
          (item) => item is Map && item['_id']?.toString() == currentId,
          orElse: () => organizations.first,
        ) as Map<String, dynamic>;
        await loadWorkspaceData();
      } else {
        organization = null;
        dashboard = {};
        catalog = []; customers = []; documents = []; tasks = [];
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadWorkspaceData({bool syncPending = true}) async {
    final id = organization?['_id']?.toString();
    if (id == null) return;
    try {
      final encoded = Uri.encodeComponent(id);
      final results = await Future.wait([
        app.api.call('GET', '/api/business/organizations/$encoded/dashboard'),
        app.api.call('GET', '/api/business/organizations/$encoded/catalog'),
        app.api.call('GET', '/api/business/organizations/$encoded/customers'),
        app.api.call('GET', '/api/business/organizations/$encoded/documents'),
        app.api.call('GET', '/api/business/organizations/$encoded/tasks'),
      ]);
      dashboard = Map<String, dynamic>.from(results[0]['metrics'] ?? {});
      catalog = List<dynamic>.from(results[1]['items'] ?? []);
      customers = List<dynamic>.from(results[2]['customers'] ?? []);
      documents = List<dynamic>.from(results[3]['documents'] ?? []);
      tasks = List<dynamic>.from(results[4]['tasks'] ?? []);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    if (syncPending && error == null) {
      final applied = await _flushOfflineQueue(id);
      if (applied > 0) { await loadWorkspaceData(syncPending: false); return; }
    }
    if (mounted) setState(() {});
  }

  Future<void> createOrganization() async {
    final name = TextEditingController();
    final industry = ValueNotifier<String>('retail');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create a business workspace'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Business name')),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: industry,
            builder: (_, value, __) => DropdownButtonFormField<String>(
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Industry'),
              items: const [
                DropdownMenuItem(value: 'retail', child: Text('Retail / wholesale')),
                DropdownMenuItem(value: 'consulting', child: Text('Consultants / agencies')),
                DropdownMenuItem(value: 'tourism', child: Text('Tourism / hospitality')),
                DropdownMenuItem(value: 'logistics', child: Text('Transport / logistics')),
                DropdownMenuItem(value: 'construction', child: Text('Construction / trades')),
                DropdownMenuItem(value: 'salon', child: Text('Salon / personal services')),
                DropdownMenuItem(value: 'education', child: Text('Schools / training')),
                DropdownMenuItem(value: 'agriculture', child: Text('Agriculture / produce')),
                DropdownMenuItem(value: 'real_estate', child: Text('Real estate / property')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (next) { if (next != null) industry.value = next; },
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Create')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    try {
      await app.api.call('POST', '/api/business/organizations', {'name': name.text.trim(), 'industry': industry.value});
      await loadOrganizations();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> createRecord(String kind) async {
    final name = TextEditingController();
    final detail = TextEditingController();
    final amount = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final docType = ValueNotifier<String>('quote');
    final id = organization?['_id']?.toString();
    if (id == null) return;
    final title = kind == 'catalog' ? 'Add product or service' : kind == 'customer' ? 'Add customer' : kind == 'document' ? 'Create quotation' : 'Create follow-up task';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: kind == 'catalog' ? 'Product / service name' : kind == 'customer' ? 'Customer name' : kind == 'document' ? 'Quotation title / item' : 'Task title')),
          if (kind == 'catalog') ...[
            TextField(controller: detail, decoration: const InputDecoration(labelText: 'Description')),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price')),
            TextField(controller: quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stock quantity')),
          ] else if (kind == 'customer') ...[
            TextField(controller: detail, decoration: const InputDecoration(labelText: 'Email or phone')),
          ] else if (kind == 'document') ...[
            ValueListenableBuilder<String>(valueListenable: docType, builder: (_, value, __) => DropdownButtonFormField<String>(initialValue: value, decoration: const InputDecoration(labelText: 'Document type'), items: const [DropdownMenuItem(value: 'quote', child: Text('Quotation')), DropdownMenuItem(value: 'invoice', child: Text('Invoice')), DropdownMenuItem(value: 'order', child: Text('Sales order'))], onChanged: (next) { if (next != null) docType.value = next; })),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Unit price')),
            TextField(controller: quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity')),
          ] else ...[
            TextField(controller: detail, decoration: const InputDecoration(labelText: 'Notes / description')),
          ],
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(id)}';
      if (kind == 'catalog') {
        final price = double.tryParse(amount.text) ?? -1;
        if (price < 0) throw const FormatException('Enter a valid non-negative price.');
        await app.api.call('POST', '$base/catalog', {'name': name.text.trim(), 'description': detail.text.trim(), 'price': price, 'stock': int.tryParse(quantity.text) ?? 0});
      } else if (kind == 'customer') {
        final contact = detail.text.trim();
        await app.api.call('POST', '$base/customers', {'name': name.text.trim(), if (contact.contains('@')) 'email': contact else 'phone': contact});
      } else if (kind == 'document') {
        final price = double.tryParse(amount.text) ?? -1;
        final count = int.tryParse(quantity.text) ?? 0;
        if (price < 0 || count < 1) throw const FormatException('Enter a valid price and quantity.');
        await app.api.call('POST', '$base/documents', {'type': docType.value, 'items': [{'name': name.text.trim(), 'quantity': count, 'unitPrice': price}]});
      } else {
        await app.api.call('POST', '$base/tasks', {'title': name.text.trim(), 'description': detail.text.trim(), 'type': 'follow_up'});
      }
      await loadWorkspaceData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Business record saved.')));
    } catch (e) {
      if ((e is http.ClientException || e is TimeoutException) && kind != 'document') {
        final entityType = kind == 'catalog' ? 'catalog' : kind == 'customer' ? 'customer' : 'task';
        final changes = kind == 'catalog' ? {'name': name.text.trim(), 'description': detail.text.trim(), 'price': double.tryParse(amount.text) ?? 0, 'stock': int.tryParse(quantity.text) ?? 0} : kind == 'customer' ? {'name': name.text.trim(), if (detail.text.trim().contains('@')) 'email': detail.text.trim() else 'phone': detail.text.trim()} : {'title': name.text.trim(), 'description': detail.text.trim(), 'type': 'follow_up'};
        await _enqueueOfflineCreate(id, entityType, changes);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to the device queue. It will sync when connectivity returns.')));
      } else if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }


  String _offlineQueueKey(String id) => 'chatify_business_offline_$id';
  String _offlineIssuesKey(String id) => 'chatify_business_sync_issues_$id';

  // Persist only offline record creates; each mutation ID makes retry safe if the response is lost.
  Future<void> _enqueueOfflineCreate(String id, String entityType, Map<String, dynamic> changes) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    queue.add(jsonEncode({'mutationId': 'mobile:$entityType:${DateTime.now().microsecondsSinceEpoch}', 'operation': 'create', 'entityType': entityType, 'changes': changes}));
    await prefs.setStringList(key, queue);
    if (mounted) setState(() => pendingOfflineCount = queue.length);
  }

  Future<int> _flushOfflineQueue(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    if (queue.isEmpty) { if (mounted) setState(() => pendingOfflineCount = 0); return 0; }
    try {
      final mutations = queue.map((entry) => Map<String, dynamic>.from(jsonDecode(entry) as Map)).toList();
      final response = await app.api.call('POST', '/api/business/organizations/${Uri.encodeComponent(id)}/sync', {'mutations': mutations});
      final results = List<dynamic>.from(response['results'] ?? []);
      final byId = <String, Map<String, dynamic>>{for (final result in results.whereType<Map>()) result['mutationId'].toString(): Map<String, dynamic>.from(result)};
      final remaining = <String>[];
      final issues = prefs.getStringList(_offlineIssuesKey(id)) ?? <String>[];
      var applied = 0;
      for (final entry in queue) {
        final mutation = Map<String, dynamic>.from(jsonDecode(entry) as Map);
        final result = byId[mutation['mutationId'].toString()];
        if (result == null) { remaining.add(entry); }
        else if (result['status'] == 'applied') { applied++; }
        else { issues.add(jsonEncode({'mutation': mutation, 'result': result})); }
      }
      await prefs.setStringList(key, remaining);
      await prefs.setStringList(_offlineIssuesKey(id), issues.take(100).toList());
      if (mounted) setState(() { pendingOfflineCount = remaining.length; syncConflicts = issues.take(100).toList(); });
      if (issues.isNotEmpty && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Some offline changes need review in Business Tools.')));
      return applied;
    } catch (_) {
      if (mounted) setState(() => pendingOfflineCount = queue.length);
      return 0;
    }
  }

  // Seller M-Pesa settings start with the registered account phone, but owners can
  // save a different Kenyan number for customer-facing storefront payments.
  Future<void> _configureMpesaNumbers() async {
    var registeredPhone = app.user?['phone']?.toString() ?? '';
    final slug = organization?['slug']?.toString() ?? '';
    // The storefront API resolves the actual owner account default, even if a manager is editing settings.
    if (slug.isNotEmpty) {
      try {
        final storefrontResponse = await app.api.call('GET', '/api/storefront/${Uri.encodeComponent(slug)}');
        final sellerDefault = storefrontResponse['storefront']?['sellerMpesaPhone']?.toString() ?? '';
        if (sellerDefault.isNotEmpty) registeredPhone = sellerDefault;
      } catch (_) {
        // Keep the signed-in user's registered number as a useful offline/fallback default.
      }
    }
    final currentSettings = organization?['settings'] is Map
        ? Map<String, dynamic>.from(organization!['settings'] as Map)
        : <String, dynamic>{};
    final phone = TextEditingController(
      text: currentSettings['mpesaRecipientPhone']?.toString().isNotEmpty == true
          ? currentSettings['mpesaRecipientPhone'].toString()
          : registeredPhone,
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Seller M-Pesa number'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Registered account number: ${registeredPhone.isEmpty ? 'Not set' : registeredPhone}'),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Customer payment number',
              hintText: '0712345678',
              helperText: 'Starts with your registered number. Change it if you want customers to pay using another Kenyan M-Pesa number. Leave blank to use your registered account number.',
              prefixIcon: Icon(Icons.phone_android),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save number')),
        ],
      ),
    );
    if (accepted != true) return;
    final id = organization?['_id']?.toString();
    if (id == null) return;
    try {
      await app.api.call('PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}', {
        'settings': {'mpesaRecipientPhone': phone.text.trim()},
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Seller M-Pesa number saved.')));
      await loadOrganizations();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _configureTaxProfile() async {
    final country = TextEditingController(text: organization?['country']?.toString() ?? 'KE');
    final currency = TextEditingController(text: organization?['currency']?.toString() ?? 'KES');
    final rate = TextEditingController(text: '0');
    String mode = 'exclusive';
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Text('Tax and currency profile'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: country, maxLength: 2, decoration: const InputDecoration(labelText: 'Country code (e.g. KE)')),
        TextField(controller: currency, maxLength: 3, decoration: const InputDecoration(labelText: 'Currency (e.g. KES)')),
        TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Tax rate (%)')),
        DropdownButtonFormField<String>(initialValue: mode, decoration: const InputDecoration(labelText: 'Tax treatment'), items: const [DropdownMenuItem(value: 'exclusive', child: Text('Tax added on top')), DropdownMenuItem(value: 'inclusive', child: Text('Tax included')), DropdownMenuItem(value: 'none', child: Text('No tax'))], onChanged: (value) { if (value != null) setDialogState(() => mode = value); }),
        const Text('Confirm local rates with your accountant or tax authority.', style: TextStyle(fontSize: 12)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save'))],
    )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call('PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}/tax-profile', {'country': country.text.trim().toUpperCase(), 'currency': currency.text.trim().toUpperCase(), 'rate': double.tryParse(rate.text) ?? -1, 'mode': mode});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response['notice']?.toString() ?? 'Tax profile saved.')));
      await loadOrganizations();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _translateBusinessText() async {
    final source = TextEditingController();
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Text('Translate business text'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: source, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Text to translate')),
        TextField(controller: target, decoration: const InputDecoration(labelText: 'Target language')),
        CheckboxListTile(value: consent, contentPadding: EdgeInsets.zero, title: const Text('I consent to sending this text to the configured AI provider'), onChanged: (value) => setDialogState(() => consent = value ?? false)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: consent ? () => Navigator.pop(dialogContext, true) : null, child: const Text('Translate'))],
    )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call('POST', '/api/business/organizations/${Uri.encodeComponent(id)}/translate', {'text': source.text, 'targetLanguage': target.text.trim(), 'consent': true});
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Translation'), content: SelectableText(response['translated']?.toString() ?? 'No translation returned.'), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))]));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }


  Future<void> _translateVoice() async {
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Text('Voice message translation'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: target, decoration: const InputDecoration(labelText: 'Translate speech into')),
        CheckboxListTile(value: consent, contentPadding: EdgeInsets.zero, title: const Text('I consent to sending this audio to the configured AI provider'), onChanged: (value) => setDialogState(() => consent = value ?? false)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: consent ? () => Navigator.pop(dialogContext, true) : null, child: const Text('Choose audio'))],
    )));
    if (accepted != true) return;
    try {
      final selected = await FilePicker.platform.pickFiles(type: FileType.audio, withData: true, allowMultiple: false);
      if (selected == null || selected.files.isEmpty) return;
      final file = selected.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty || bytes.length > 11 * 1024 * 1024) throw const FormatException('Choose an audio file smaller than 11 MB.');
      final extension = (file.extension ?? '').toLowerCase();
      final mime = switch (extension) {
        'mp3' || 'mpeg' => 'audio/mpeg',
        'm4a' || 'mp4' => 'audio/mp4',
        'wav' => 'audio/wav',
        'ogg' => 'audio/ogg',
        'webm' => 'audio/webm',
        _ => throw const FormatException('Supported audio formats: MP3, M4A, WAV, OGG and WebM.'),
      };
      final id = organization!['_id'].toString();
      final response = await app.api.call('POST', '/api/business/organizations/${Uri.encodeComponent(id)}/voice-translate', {'audioBase64': base64Encode(bytes), 'mimeType': mime, 'targetLanguage': target.text.trim(), 'consent': true});
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Voice translation'),
        content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Transcription', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(response['transcription']?.toString() ?? ''),
          const SizedBox(height: 12),
          const Text('Translation', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(response['translated']?.toString() ?? ''),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
      ));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _memorySuggestions() async {
    final source = TextEditingController();
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Business Memory suggestions'), content: TextField(controller: source, autofocus: true, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Paste a conversation or business note')), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Find suggestions'))]));
    if (accepted != true || source.text.trim().isEmpty) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call('POST', '/api/business/organizations/${Uri.encodeComponent(id)}/memory-candidates', {'text': source.text});
      final candidates = List<dynamic>.from(response['candidates'] ?? []);
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Review suggestions'), content: SizedBox(width: 420, child: candidates.isEmpty ? const Text('No clear candidates found.') : ListView(shrinkWrap: true, children: candidates.whereType<Map>().map((item) => ListTile(title: Text(item['title']?.toString() ?? 'Suggestion'), subtitle: Text('${item['type']}: ${item['description']}'))).toList())), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))]));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _sendCustomerMessage() async {
    final eligible = customers.whereType<Map>().toList();
    if (eligible.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add a customer before sending a message.'))); return; }
    String? customerId = eligible.first['_id']?.toString();
    String channel = 'whatsapp';
    bool confirmedOptIn = false;
    final message = TextEditingController();
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Text('Message a customer'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(initialValue: customerId, decoration: const InputDecoration(labelText: 'Customer'), items: eligible.map((item) => DropdownMenuItem<String>(value: item['_id']?.toString(), child: Text(item['name']?.toString() ?? 'Customer', overflow: TextOverflow.ellipsis))).toList(), onChanged: (value) => setDialogState(() => customerId = value)),
        DropdownButtonFormField<String>(initialValue: channel, decoration: const InputDecoration(labelText: 'Channel'), items: const [DropdownMenuItem(value: 'whatsapp', child: Text('WhatsApp')), DropdownMenuItem(value: 'sms', child: Text('SMS'))], onChanged: (value) { if (value != null) setDialogState(() => channel = value); }),
        TextField(controller: message, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Message')),
        CheckboxListTile(value: confirmedOptIn, contentPadding: EdgeInsets.zero, title: const Text('Customer has explicitly opted in'), onChanged: (value) => setDialogState(() => confirmedOptIn = value ?? false)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: confirmedOptIn && message.text.trim().isNotEmpty ? () => Navigator.pop(dialogContext, true) : null, child: const Text('Send'))],
    )));
    if (accepted != true || customerId == null) return;
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      await app.api.call('PATCH', '$base/customers/${Uri.encodeComponent(customerId!)}/messaging-consent', {'consent': true});
      final response = await app.api.call('POST', '$base/communications/send', {'customerId': customerId, 'channel': channel, 'message': message.text.trim()});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response['notice']?.toString() ?? 'Message submitted.')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _createScheduledWorkflow() async {
    final name = TextEditingController(text: 'Daily follow-up reminder');
    final interval = TextEditingController(text: '60');
    final actionText = TextEditingController(text: 'Review open customer follow-ups');
    String action = 'create_task';
    final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Text('Scheduled workflow'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Workflow name')),
        TextField(controller: interval, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Repeat every minutes (5–10080)')),
        DropdownButtonFormField<String>(initialValue: action, decoration: const InputDecoration(labelText: 'Action'), items: const [DropdownMenuItem(value: 'create_task', child: Text('Create follow-up task')), DropdownMenuItem(value: 'notify_team', child: Text('Notify team in Chatify'))], onChanged: (value) { if (value != null) setDialogState(() => action = value); }),
        TextField(controller: actionText, decoration: InputDecoration(labelText: action == 'create_task' ? 'Task title' : 'Notification')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Create and enable'))],
    )));
    if (accepted != true) return;
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      final created = await app.api.call('POST', '$base/workflows', {'name': name.text.trim(), 'trigger': 'schedule', 'scheduleEveryMinutes': int.tryParse(interval.text) ?? 60, 'actions': [{'actionType': action, 'config': action == 'create_task' ? {'title': actionText.text.trim()} : {'message': actionText.text.trim()}}]});
      final workflowId = (created['workflow'] as Map?)?['_id']?.toString();
      if (workflowId == null) throw const FormatException('Workflow was created but its ID was missing.');
      await app.api.call('POST', '$base/workflows/${Uri.encodeComponent(workflowId)}/test', {'sample': {'source': 'mobile setup'}});
      await app.api.call('PATCH', '$base/workflows/${Uri.encodeComponent(workflowId)}', {'enabled': true});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Workflow enabled. Keep the backend worker running.')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _invoiceIntegration(String documentId, String action) async {
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(documentId)}';
      Map<String, dynamic> response;
      if (action == 'stripe' || action == 'paypal') {
        final providerRoute = action == 'stripe' ? 'stripe-checkout' : 'paypal-checkout';
        response = await app.api.call('POST', '$base/$providerRoute', {});
        final checkoutUrl = response['payment'] is Map ? (response['payment'] as Map)['checkoutUrl']?.toString() : null;
        if (checkoutUrl == null || !await launchUrl(Uri.parse(checkoutUrl), mode: LaunchMode.externalApplication)) {
          if (mounted && checkoutUrl != null) await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('Hosted checkout'), content: SelectableText(checkoutUrl), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]));
        }
      } else if (action == 'mpesa') {
        final phone = TextEditingController();
        final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Request M-Pesa payment'), content: TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer M-Pesa phone')), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Send STK prompt'))]));
        if (accepted != true) return;
        response = await app.api.call('POST', '$base/mpesa-stk', {'phone': phone.text.trim()});
      } else {
        response = await app.api.call('POST', '$base/etims-submit', {});
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response['notice']?.toString() ?? 'Request submitted.')));
      await loadWorkspaceData();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _showDocumentActions(Map item) async {
    final type = item['type']?.toString() ?? '';
    final status = item['status']?.toString() ?? '';
    final action = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Wrap(children: [
      ListTile(title: Text(item['number']?.toString() ?? 'Sales document'), subtitle: Text('Status: $status')),
      if (status == 'draft') ListTile(leading: const Icon(Icons.send), title: const Text('Issue / send document'), onTap: () => Navigator.pop(context, 'issue')),
      if (type == 'invoice' && status != 'draft' && !['paid','cancelled','rejected','fulfilled'].contains(status)) ListTile(leading: const Icon(Icons.credit_card), title: const Text('Pay online (Stripe)'), onTap: () => Navigator.pop(context, 'stripe')),
      if (type == 'invoice' && status != 'draft' && !['paid','cancelled','rejected','fulfilled'].contains(status)) ListTile(leading: const Icon(Icons.account_balance_wallet_outlined), title: const Text('Pay with PayPal'), onTap: () => Navigator.pop(context, 'paypal')),
      if (type == 'invoice' && status != 'draft' && !['paid','cancelled','rejected','fulfilled'].contains(status)) ListTile(leading: const Icon(Icons.payments), title: const Text('Request M-Pesa STK payment'), onTap: () => Navigator.pop(context, 'mpesa')),
      if (type == 'invoice' && status != 'draft' && !['cancelled','rejected'].contains(status)) ListTile(leading: const Icon(Icons.receipt_long), title: const Text('Submit through configured eTIMS gateway'), onTap: () => Navigator.pop(context, 'etims')),
    ])));
    if (action == null) return;
    final id = item['_id']?.toString();
    if (id == null) return;
    try {
      if (action == 'issue') {
        final path = '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(id)}/status';
        await app.api.call('PATCH', path, {'status': 'sent'});
        await loadWorkspaceData();
      } else { await _invoiceIntegration(id, action); }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Widget toolsPanel() => ListView(padding: const EdgeInsets.all(12), children: [
    Card(child: ListTile(leading: const Icon(Icons.public), title: const Text('Tax and currency profile'), subtitle: const Text('Configure jurisdiction and tax treatment'), trailing: const Icon(Icons.chevron_right), onTap: _configureTaxProfile)),
    Card(child: ListTile(leading: const Icon(Icons.translate), title: const Text('Translate business text'), subtitle: const Text('Consent-gated AI translation'), trailing: const Icon(Icons.chevron_right), onTap: _translateBusinessText)),
    Card(child: ListTile(leading: const Icon(Icons.mic_none), title: const Text('Translate voice message'), subtitle: const Text('Transcribe and translate an audio file with consent'), trailing: const Icon(Icons.chevron_right), onTap: _translateVoice)),
    Card(child: ListTile(leading: const Icon(Icons.psychology_alt), title: const Text('Business Memory suggestions'), subtitle: const Text('Find possible tasks, dates and payment details'), trailing: const Icon(Icons.chevron_right), onTap: _memorySuggestions)),
    Card(child: ListTile(leading: const Icon(Icons.mark_chat_unread_outlined), title: const Text('Message a customer'), subtitle: const Text('WhatsApp / SMS; opt-in required'), trailing: const Icon(Icons.chevron_right), onTap: _sendCustomerMessage)),
    Card(child: ListTile(leading: const Icon(Icons.schedule), title: const Text('Scheduled workflow'), subtitle: const Text('Create, test and enable an allowed action'), trailing: const Icon(Icons.chevron_right), onTap: _createScheduledWorkflow)),
    Card(child: ListTile(leading: const Icon(Icons.sync), title: Text('Sync offline records ($pendingOfflineCount)'), subtitle: Text(syncConflicts.isEmpty ? 'Queued creates sync when connected' : '${syncConflicts.length} changes need review'), trailing: const Icon(Icons.chevron_right), onTap: () async { final id = organization!['_id'].toString(); final applied = await _flushOfflineQueue(id); if (applied > 0) await loadWorkspaceData(syncPending: false); if (syncConflicts.isNotEmpty && mounted) await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('Sync conflicts'), content: SizedBox(width: 420, child: ListView(shrinkWrap: true, children: syncConflicts.map((entry) { final item = jsonDecode(entry) as Map; final result = item['result'] as Map? ?? {}; return ListTile(title: Text(result['status']?.toString() ?? 'Needs review'), subtitle: Text(result['error']?.toString() ?? result['reason']?.toString() ?? 'Server record changed; compare versions before retrying.')); }).toList())), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))])); })),
  ]);

  Widget metric(String label, dynamic value, IconData icon) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Icon(icon, size: 24),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value?.toString() ?? '0', style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ])),
      ]),
    ),
  );

  Widget recordList(List<dynamic> records, String kind, IconData icon) {
    if (records.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('No $kind yet. Use Add to create your first record.', textAlign: TextAlign.center)));
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: records.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final item = records[index];
        if (item is! Map) return const SizedBox.shrink();
        final title = item['name']?.toString() ?? item['title']?.toString() ?? item['number']?.toString() ?? kind;
        final subtitle = item['description']?.toString() ?? item['company']?.toString() ?? item['status']?.toString() ?? '';
        final amount = item['price'] ?? item['total'];
        return ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: amount == null ? null : Text('${item['currency'] ?? 'KES'} $amount'),
          onTap: kind == 'sales documents' ? () => _showDocumentActions(Map<String, dynamic>.from(item)) : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null && organizations.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.business_outlined, size: 48),
        const SizedBox(height: 12),
        Text(error!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: loadOrganizations, child: const Text('Retry')),
      ])));
    }
    if (organization == null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.storefront_outlined, size: 56),
        const SizedBox(height: 12),
        Text('Turn conversations into business', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Create a workspace to manage customers, products, quotations and follow-ups alongside your conversations.', textAlign: TextAlign.center),
        const SizedBox(height: 18),
        FilledButton.icon(onPressed: createOrganization, icon: const Icon(Icons.add_business), label: const Text('Create business workspace')),
      ])));
    }
    final metrics = dashboard;
    return DefaultTabController(
      length: 5,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
          Expanded(child: DropdownButtonHideUnderline(child: DropdownButton<String>(
            isExpanded: true,
            value: organization!['_id']?.toString(),
            items: organizations.whereType<Map>().map((item) => DropdownMenuItem<String>(value: item['_id'].toString(), child: Text(item['name']?.toString() ?? 'Business', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (id) async {
              if (id == null) return;
              setState(() { organization = organizations.whereType<Map>().firstWhere((item) => item['_id'].toString() == id).cast<String, dynamic>(); loading = true; });
              await loadWorkspaceData();
              if (mounted) setState(() => loading = false);
            },
          ))),
          IconButton(tooltip: 'Open customer storefront', onPressed: () {
            final slug = organization?['slug']?.toString() ?? '';
            if (slug.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This workspace has no storefront slug yet.'))); return; }
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StorefrontPage(slug: slug)));
          }, icon: const Icon(Icons.storefront_outlined)),
          IconButton(tooltip: 'Configure seller M-Pesa number', onPressed: _configureMpesaNumbers, icon: const Icon(Icons.phone_android)),
          IconButton(tooltip: 'Refresh business data', onPressed: loadOrganizations, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Add business workspace', onPressed: createOrganization, icon: const Icon(Icons.add_business)),
        ])),
        SizedBox(height: 118, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          SizedBox(width: 170, child: metric('Customers', metrics['customers'], Icons.people_outline)),
          SizedBox(width: 170, child: metric('Products / services', metrics['activeCatalogItems'], Icons.inventory_2_outlined)),
          SizedBox(width: 170, child: metric('Open tasks', metrics['openTasks'], Icons.task_alt)),
          SizedBox(width: 170, child: metric('Open cases', metrics['openCases'], Icons.support_agent_outlined)),
        ])),
        const TabBar(isScrollable: true, tabs: [
          Tab(text: 'Catalogue'), Tab(text: 'Customers'), Tab(text: 'Sales'), Tab(text: 'Tasks'), Tab(text: 'Tools'),
        ]),
        Expanded(child: TabBarView(children: [
          Column(children: [Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: saving ? null : () => createRecord('catalog'), icon: const Icon(Icons.add), label: const Text('Add product / service'))), Expanded(child: recordList(catalog, 'products or services', Icons.inventory_2_outlined))]),
          Column(children: [Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: saving ? null : () => createRecord('customer'), icon: const Icon(Icons.add), label: const Text('Add customer'))), Expanded(child: recordList(customers, 'customers', Icons.person_outline))]),
          Column(children: [Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: saving ? null : () => createRecord('document'), icon: const Icon(Icons.add), label: const Text('Create quotation'))), Expanded(child: recordList(documents, 'sales documents', Icons.receipt_long_outlined))]),
          Column(children: [Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: saving ? null : () => createRecord('task'), icon: const Icon(Icons.add), label: const Text('Add task / follow-up'))), Expanded(child: recordList(tasks, 'tasks', Icons.task_alt))]),
          toolsPanel(),
        ])),
        if (saving) const LinearProgressIndicator(),
        if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]),
    );
  }
}
