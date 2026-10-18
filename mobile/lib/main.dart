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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'security/chatify_e2ee.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final http.Client client;
  Api({http.Client? client}) : client = client ?? http.Client();
  String get base => const String.fromEnvironment('CHATIFY_API',
      defaultValue: 'https://chatify-api-c1eh.onrender.com');
  String? token;
  Future<void> restore() async {
    token = await _secureStorage.read(key: 'token');
    // Migrate the previous preferences-based token once, then remove the less-protected copy.
    if (token == null) {
      final preferences = await SharedPreferences.getInstance();
      final legacyToken = preferences.getString('token');
      if (legacyToken != null && legacyToken.isNotEmpty) {
        token = legacyToken;
        await _secureStorage.write(key: 'token', value: legacyToken);
        await preferences.remove('token');
      }
    }
  }
  Future<void> saveToken(String value) async {
    token = value;
    await _secureStorage.write(key: 'token', value: value);
  }
  Future<void> clearToken() async {
    token = null;
    await _secureStorage.delete(key: 'token');
    await (await SharedPreferences.getInstance()).remove('token');
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
    Future<http.Response> sendRequest() {
      if (method == 'POST') {
        return client.post(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'PATCH') {
        return client.patch(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'PUT') {
        return client.put(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'DELETE') {
        return client.delete(u, headers: h,
            body: body == null ? null : jsonEncode(body));
      }
      return client.get(u, headers: h);
    }

    late http.Response r;
    try {
      r = await sendRequest().timeout(requestTimeout);
    } on TimeoutException {
      // A sleeping free-tier API may need to wake after a long idle period.
      // Retry only safe GET requests; never automatically repeat payment or write requests.
      if (method != 'GET') rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        r = await sendRequest().timeout(const Duration(seconds: 25));
      } on TimeoutException {
        throw ApiException(408,
            'Chatify is taking longer than expected to respond. Check your connection and retry.');
      }
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
        throw ApiException(
            r.statusCode,
            'Chatify API returned an invalid JSON response for $path '
            '(HTTP ${r.statusCode}).');
      }
    } else {
      decoded = <String, dynamic>{};
    }
    if (r.statusCode >= 400) {
      throw ApiException(
          r.statusCode,
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

  Future<Map<String, dynamic>> publicStatus() async {
    final response = await client
        .get(Uri.parse('$base/api/status'))
        .timeout(const Duration(seconds: 10));
    final decoded = jsonDecode(response.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Service status response was not an object.');
  }
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
Map<String, dynamic>? findReplyTarget(
    List<dynamic> conversationMessages, dynamic replyTo) {
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
  final currentEmail =
      currentUser?['email']?.toString().trim().toLowerCase() ?? '';
  final rawParticipants = conversation['participants'];
  if (rawParticipants is! List) return null;

  String? firstAvailableName;
  for (final raw in rawParticipants) {
    if (raw is! Map) continue;
    final participant = Map<String, dynamic>.from(raw);
    final nested = participant['user'] is Map
        ? Map<String, dynamic>.from(participant['user'] as Map)
        : <String, dynamic>{};
    final id = (participant['_id'] ??
                participant['id'] ??
                participant['userId'] ??
                nested['_id'] ??
                nested['id'])
            ?.toString() ??
        '';
    final email = (participant['email'] ?? nested['email'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    final name = (participant['name'] ??
                nested['name'] ??
                participant['displayName'] ??
                nested['displayName'] ??
                participant['username'] ??
                nested['username'])
            ?.toString()
            .trim() ??
        '';

    // Exclude the signed-in user by ID or email before choosing the chat peer.
    if ((id.isNotEmpty && currentIds.contains(id)) ||
        (currentEmail.isNotEmpty &&
            email.isNotEmpty &&
            email == currentEmail)) {
      continue;
    }
    if (name.isNotEmpty) return name;
    // Keep the first usable fallback name; null needs no explicit assignment.
  }
  return firstAvailableName;
}

// Extract candidate memories locally on the device. This is intentionally heuristic and
// suggestion-only: decrypted end-to-end encrypted messages never leave the device for analysis.
List<Map<String, dynamic>> extractMemoryCandidatesLocally(String input) {
  final text = input.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length < 8) return [];
  final candidates = <Map<String, dynamic>>[];
  if (RegExp(
    r'\b(meet(?:ing)?|appointment|doctor|interview|flight|deadline|due date|reservation|call with|scheduled|tomorrow|tonight|today|next week|this (?:morning|afternoon|evening)|on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    candidates.add({
      'type': 'EVENT',
      'title': RegExp(r'\b(deadline|due date)\b', caseSensitive: false).hasMatch(text)
          ? 'Deadline'
          : RegExp(r'\b(doctor|appointment)\b', caseSensitive: false).hasMatch(text)
              ? 'Appointment'
              : 'Upcoming event',
      'description': text,
    });
  }
  final task = RegExp(
    r'\b(?:remember to|don.t forget to|do not forget to|remind me to|need to|have to|must|todo|to-do|task is to)\s+(.+?)(?:[.!?]|$)',
    caseSensitive: false,
  ).firstMatch(text);
  if (task != null && (task.group(1)?.trim().length ?? 0) >= 4) {
    candidates.add({
      'type': 'TASK',
      'title': 'Reminder',
      'description': task.group(1)!.trim(),
    });
  }
  final hasMoney = RegExp(
    r'\b(?:KES|KSh|shillings?)\s*[0-9][0-9,]*(?:\.\d{1,2})?\b|\b(?:pay|paid|owe|owed|costs?|rent|bill|payment)\b[^.!?]{0,70}\b[0-9][0-9,]*(?:\.\d{1,2})?\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (hasMoney) {
    candidates.add({
      'type': 'PAYMENT',
      'title': 'Payment or amount',
      'description': text,
    });
  }
  if (RegExp(
    r'\b(?:my birthday is|my anniversary is|i live in|i work at|i work in|i am based in|i.m based in|my job is|i work as|my goal is|my favorite|my favourite|i prefer|my child.s name is|my dog.s name is|my cat.s name is)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    candidates.add({
      'type': 'NOTE',
      'title': RegExp(r'birthday|anniversary', caseSensitive: false).hasMatch(text)
          ? 'Important date'
          : RegExp(r'prefer|favorite|favourite', caseSensitive: false).hasMatch(text)
              ? 'Preference'
              : RegExp(r'work|job', caseSensitive: false).hasMatch(text)
                  ? 'Work detail'
                  : 'Personal detail',
      'description': text,
    });
  }
  final seen = <String>{};
  return candidates.where((item) {
    final key = '${item['type']}:${item['title']}';
    return seen.add(key);
  }).take(3).toList();
}

// Shared app state. Screens listen to this object and rebuild after login, chat, contact, memory, or payment data changes.
class AppState extends ChangeNotifier {
  final Api api;
  ThemeMode themeMode = ThemeMode.light;
  bool ready = false;
  bool authRequested = false;
  bool startRegistration = false;
  Map<String, dynamic>? user;
  String? restoreError;
  String? encryptionError;
  final Set<String> onlineUserIds = {};
  // Monotonic counter lets chat-list screens refresh summaries without polling.
  int messageEventVersion = 0;
  io.Socket? _presenceSocket;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  String? _registeredPushToken;
  AppState({Api? api, bool autoInit = true}) : api = api ?? Api() {
    if (autoInit) init();
  }

  // Update the signed-in account and notify listeners from inside ChangeNotifier.
  void updateCurrentUser(Map<String, dynamic> updatedUser) {
    user = updatedUser;
    notifyListeners();
  }

  Future<void> init() async {
    ready = false;
    restoreError = null;
    await api.restore();
    final preferences = await SharedPreferences.getInstance();
    themeMode = preferences.getBool('chatify_dark_mode') == true
        ? ThemeMode.dark
        : ThemeMode.light;
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
      try {
        await ensureEncryptionKey();
      } catch (error) {
        // Do not block sign-in, but encrypted sends remain disabled until key recovery.
        encryptionError = error.toString();
      }
      _connectPresence();
      await _initializePushNotifications();
    }
    ready = true;
    notifyListeners();
  }

  /// Creates the device-local key on first use and registers only its public half.
  Future<String> ensureEncryptionKey() async {
    final accountId = user?['id']?.toString() ?? '';
    if (accountId.isEmpty) throw StateError('Sign in before enabling encryption.');
    final registered = user?['encryptionPublicKey']?.toString();
    final publicKey = await ChatifyE2EE.instance.publicKeyFor(
      accountId,
      registeredPublicKey: (registered == null || registered.isEmpty) ? null : registered,
    );
    if (registered == null || registered.isEmpty) {
      await api.call('PUT', '/api/users/me/encryption-key', {'publicKey': publicKey});
      user!['encryptionPublicKey'] = publicKey;
      encryptionError = null;
      notifyListeners();
    }
    return publicKey;
  }

  /// Rebuilds the presence connection after credentials rotate.
  void refreshRealtimeAuthentication() {
    _connectPresence();
    // Notify active conversation widgets so their sockets can rotate the same token.
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
    // Refresh the chat list after the socket reconnects so messages sent while
    // this device was offline are reflected in conversation previews.
    _presenceSocket!.onConnect((_) {
      messageEventVersion++;
      notifyListeners();
    });
    // Play one alert for incoming messages even when the user is viewing another tab.
    // The active chat screen deliberately does not play a second copy of this sound.
    _presenceSocket!.on('message:new', (data) {
      if (data is! Map) return;
      final senderId = data['senderId']?.toString();
      final currentId = user?['id']?.toString();
      messageEventVersion++;
      notifyListeners();
      if (senderId != null && senderId.isNotEmpty && senderId != currentId) {
        unawaited(SystemSound.play(SystemSoundType.alert));
      }
    });
    _presenceSocket!.on('presence:initial', (data) {
      if (data is! Map || data['userIds'] is! List) return;
      onlineUserIds
        ..clear()
        ..addAll((data['userIds'] as List).map((id) => id.toString()));
      notifyListeners();
    });
    _presenceSocket!.on('user:online', (data) {
      if (data is Map &&
          data['userId'] != null &&
          onlineUserIds.add(data['userId'].toString())) {
        notifyListeners();
      }
    });
    _presenceSocket!.on('user:offline', (data) {
      if (data is Map &&
          data['userId'] != null &&
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
        unawaited(SystemSound.play(SystemSoundType.alert));
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

  Future<String?> auth(
      bool reg, String name, String email, String pass, String phone) async {
    try {
      final d = await api.call(
          'POST',
          reg ? '/api/auth/register' : '/api/auth/login',
          reg
              ? {
                  'name': name,
                  'email': email,
                  'password': pass,
                  'phone': normalizeKenyanPhone(phone)
                }
              : {'email': email, 'password': pass});
      if (reg && d['verificationRequired'] == true) {
        return d['message']?.toString() ??
            'Check your email and confirm your address before signing in.';
      }
      await api.saveToken(d['token'].toString());
      user = Map<String, dynamic>.from(d['user']);
      try {
        await ensureEncryptionKey();
      } catch (error) {
        encryptionError = error.toString();
      }
      _connectPresence();
      await _initializePushNotifications();
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<void> setDarkMode(bool enabled) async {
    themeMode = enabled ? ThemeMode.dark : ThemeMode.light;
    await (await SharedPreferences.getInstance())
        .setBool('chatify_dark_mode', enabled);
    notifyListeners();
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
    await api.clearToken();
    user = null;
    authRequested = false;
    startRegistration = false;
    restoreError = null;
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
        themeMode: context.watch<AppState>().themeMode,
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7772F6),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xFFAAA7FF),
            onPrimary: const Color(0xFF191547),
            secondary: const Color(0xFF63D6C1),
            onSecondary: const Color(0xFF073B34),
            tertiary: const Color(0xFFF2C66D),
            surface: const Color(0xFF1C2433),
            onSurface: const Color(0xFFE9EDF7),
            error: const Color(0xFFFF8A80),
            outline: const Color(0xFF465268),
          ),
          scaffoldBackgroundColor: const Color(0xFF111827),
          canvasColor: const Color(0xFF111827),
          cardColor: const Color(0xFF1C2433),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF111827),
            foregroundColor: Color(0xFFE9EDF7),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF1C2433),
            hintStyle: const TextStyle(color: Color(0xFF9AA6BA)),
            labelStyle: const TextStyle(color: Color(0xFFBAC4D5)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF465268)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF465268)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFAAA7FF), width: 1.6),
            ),
          ),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Color(0xFF1C2433),
            indicatorColor: Color(0xFF35325E),
            elevation: 0,
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF273246),
            contentTextStyle: const TextStyle(color: Color(0xFFE9EDF7)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
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
            tertiary: const Color(0xFFB7791F),
            onTertiary: Colors.white,
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
                        Text(appState.restoreError!,
                            textAlign: TextAlign.center),
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
            // Open directly to authentication; the marketing homepage is no longer
            // a mandatory stop before a user can sign in or create an account.
            return Auth(startWithRegistration: appState.startRegistration);
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

  // Let customers discover published stores instead of needing to know a store slug.
  void _browseStore(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const StoreDirectoryPage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: LayoutBuilder(
        builder: (context, viewport) {
          final wide = viewport.maxWidth >= 820;
          final mobile = viewport.maxWidth < 820;
          return SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1160),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      mobile ? 16 : 30, 18, mobile ? 16 : 30, 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Use a separate action row on narrow screens so Explore stores
                      // never gets pushed off-screen by the sign-in and account buttons.
                      if (mobile) ...[
                        Row(children: [
                          Container(
                            height: 42,
                            width: 42,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [
                                Color(0xFF7167F8),
                                Color(0xFF4938D2)
                              ]),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.forum_rounded,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 11),
                          const Text('Chatify',
                              style: TextStyle(
                                  color: ink,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.8)),
                        ]),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _browseStore(context),
                              icon: const Icon(Icons.storefront_outlined),
                              label: const Text('Explore stores'),
                            ),
                            TextButton(
                                onPressed: onSignIn,
                                child: const Text('Sign in')),
                            FilledButton(
                              onPressed: onGetStarted,
                              style: FilledButton.styleFrom(
                                backgroundColor: violet,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(13)),
                              ),
                              child: const Text('Create account'),
                            ),
                          ],
                        ),
                      ] else
                        Row(children: [
                          Container(
                            height: 42,
                            width: 42,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [
                                Color(0xFF7167F8),
                                Color(0xFF4938D2)
                              ]),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.forum_rounded,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 11),
                          const Text('Chatify',
                              style: TextStyle(
                                  color: ink,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.8)),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _browseStore(context),
                            icon: const Icon(Icons.storefront_outlined),
                            label: const Text('Explore stores'),
                          ),
                          TextButton(
                              onPressed: onSignIn,
                              child: const Text('Sign in')),
                          const SizedBox(width: 5),
                          FilledButton(
                            onPressed: onGetStarted,
                            style: FilledButton.styleFrom(
                              backgroundColor: violet,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 13),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(13)),
                            ),
                            child: const Text('Create account'),
                          ),
                        ]),
                      SizedBox(height: wide ? 34 : 22),
                      if (wide)
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                flex: 4,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 26),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 7),
                                          decoration: BoxDecoration(
                                              color: const Color(0xFFE8E6FF),
                                              borderRadius:
                                                  BorderRadius.circular(30)),
                                          child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.circle,
                                                    color: Color(0xFF35C997),
                                                    size: 8),
                                                SizedBox(width: 7),
                                                Text('YOUR PEOPLE, RIGHT HERE',
                                                    style: TextStyle(
                                                        color:
                                                            Color(0xFF4D42B8),
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        letterSpacing: 0.8)),
                                              ]),
                                        ),
                                        const SizedBox(height: 20),
                                        const Text('Just chat.',
                                            style: TextStyle(
                                                color: ink,
                                                fontSize: 54,
                                                height: 1.0,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: -2.8)),
                                        const SizedBox(height: 10),
                                        const Text('The moments matter.',
                                            style: TextStyle(
                                                color: violet,
                                                fontSize: 30,
                                                height: 1.1,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -1.2)),
                                        const SizedBox(height: 16),
                                        const Text(
                                            'Real conversations. Memories worth keeping.',
                                            style: TextStyle(
                                                color: muted,
                                                fontSize: 14,
                                                height: 1.6)),
                                        const SizedBox(height: 24),
                                        FilledButton.icon(
                                          onPressed: onGetStarted,
                                          icon: const Icon(
                                              Icons.chat_bubble_outline_rounded,
                                              size: 18),
                                          label: const Text('Start chatting'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: violet,
                                            minimumSize: const Size(190, 50),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14)),
                                          ),
                                        ),
                                      ]),
                                ),
                              ),
                              const Expanded(
                                  flex: 6, child: _ConversationPreview()),
                            ])
                      else ...[
                        const Text('Your people. Your conversations.',
                            style: TextStyle(
                                color: ink,
                                fontSize: 27,
                                height: 1.1,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1)),
                        const SizedBox(height: 7),
                        const Text('Chat, remember, let go.',
                            style: TextStyle(color: muted, fontSize: 13)),
                        const SizedBox(height: 20),
                        const _ConversationPreview(),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: onGetStarted,
                          icon: const Icon(Icons.chat_bubble_outline_rounded,
                              size: 18),
                          label: const Text('Start chatting'),
                          style: FilledButton.styleFrom(
                            backgroundColor: violet,
                            minimumSize: const Size.fromHeight(50),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock_outline_rounded,
                                color: muted, size: 15),
                            SizedBox(width: 7),
                            Flexible(
                                child: Text(
                                    'Private by design · Yours to manage',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: muted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600))),
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
          BoxShadow(
              color: Color(0x1C292C57), blurRadius: 44, offset: Offset(0, 22)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.forum_rounded, color: Welcome.mint, size: 20),
              const SizedBox(width: 8),
              const Text('A little preview',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: const Color(0x223DD7B0),
                    borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Icon(Icons.circle, color: Welcome.mint, size: 7),
                    SizedBox(width: 6),
                    Text('CONNECTED',
                        style: TextStyle(
                            color: Welcome.mint,
                            fontSize: 9,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF79D8C1), Color(0xFF6C85E8)]),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(Icons.people_alt_rounded,
                          color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Weekend plans',
                              style: TextStyle(
                                  color: Welcome.ink,
                                  fontWeight: FontWeight.w800)),
                          SizedBox(height: 3),
                          Text('Maya, Alex · 3 members',
                              style: TextStyle(
                                  color: Welcome.muted, fontSize: 11)),
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
                      Icon(Icons.auto_awesome_rounded,
                          color: Color(0xFF087F6A), size: 19),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('MEMORY CARD',
                                style: TextStyle(
                                    color: Color(0xFF087F6A),
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1)),
                            SizedBox(height: 5),
                            Text('Saturday · 10:00 AM',
                                style: TextStyle(
                                    color: Color(0xFF17483E),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800)),
                            SizedBox(height: 3),
                            Text(
                                'A detail worth keeping, right when you need it.',
                                style: TextStyle(
                                    color: Color(0xFF4F766D),
                                    fontSize: 11,
                                    height: 1.45)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.add_circle_outline_rounded,
                        color: Color(0xFF929AAF), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                            color: const Color(0xFFF4F6FA),
                            borderRadius: BorderRadius.circular(13)),
                        child: const Text('Write a message…',
                            style: TextStyle(
                                color: Color(0xFF929AAF), fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 38,
                      width: 38,
                      decoration: BoxDecoration(
                          color: Welcome.violet,
                          borderRadius: BorderRadius.circular(13)),
                      child: const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white, size: 19),
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
              Icon(Icons.lock_outline_rounded,
                  color: Color(0xFFBAC3E5), size: 14),
              SizedBox(width: 7),
              Text('Your conversations, with you in control',
                  style: TextStyle(color: Color(0xFFBAC3E5), fontSize: 10)),
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
          CircleAvatar(
              radius: 15,
              backgroundColor: const Color(0xFFE7E8FF),
              child: Text(initials,
                  style: const TextStyle(
                      color: Welcome.violet,
                      fontSize: 11,
                      fontWeight: FontWeight.w800))),
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
                Text(name,
                    style: const TextStyle(
                        color: Welcome.violet,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(text,
                    style: const TextStyle(
                        color: Welcome.ink, fontSize: 12, height: 1.4)),
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
        (reg &&
            (n.text.trim().isEmpty ||
                normalizeKenyanPhone(mpesaPhone.text) == null))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Complete all fields. Password must be 8+ characters.')));
      return;
    }
    setState(() => busy = true);
    final err = await context.read<AppState>().auth(
        reg, n.text.trim(), e.text.trim(), p.text, mpesaPhone.text.trim());
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
                    color: Theme.of(context).cardColor,
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
                            prefixIcon:
                                Icon(Icons.account_balance_wallet_outlined),
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
                          reg
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
                        onPressed:
                            busy ? null : () => setState(() => reg = !reg),
                        child: Text(
                          reg
                              ? 'Already have an account? Sign in'
                              : 'Create a new account',
                        ),
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

// Platform operations dashboard. Every action is re-authorized by the API.
class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});
  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

enum _AdminSection { overview, people, payments }

class _AdminDashboardState extends State<AdminDashboard> {
  Map<String, dynamic> overview = {};
  Map<String, dynamic> platformStatus = {};
  List<dynamic> users = [], payments = [];
  bool loading = true, usersLoading = false, paymentsLoading = false, statusLoading = false;
  String? error;
  String userQuery = '', paymentStatus = '';
  String? statusError;
  int userPage = 1, paymentPage = 1, userTotal = 0, paymentTotal = 0;
  DateTime? refreshedAt;
  _AdminSection section = _AdminSection.overview;
  final TextEditingController searchController = TextEditingController();
  Api get api => context.read<AppState>().api;

  Future<void> loadOverview() async {
    if (mounted && overview.isEmpty) setState(() => loading = true);
    try {
      final result = await api.call('GET', '/api/admin/overview');
      if (!mounted) return;
      setState(() {
        overview = Map<String, dynamic>.from(result['stats'] ?? {});
        users = List<dynamic>.from(result['recentUsers'] ?? []);
        payments = List<dynamic>.from(result['recentPayments'] ?? []);
        userTotal = result['userTotal'] is num ? (result['userTotal'] as num).toInt() : userTotal;
        refreshedAt = DateTime.now();
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }

  Future<void> loadPlatformStatus() async {
    if (mounted) setState(() => statusLoading = true);
    try {
      final result = await api.publicStatus();
      if (!mounted) return;
      setState(() { platformStatus = result; statusError = null; });
    } catch (e) {
      if (mounted) setState(() { statusError = e.toString(); });
    } finally {
      if (mounted) setState(() => statusLoading = false);
    }
  }

  Future<void> refreshDashboard() async {
    await loadOverview();
    if (!mounted) return;
    await Future.wait([loadUsers(), loadPayments(), loadPlatformStatus()]);
  }

  Future<void> loadUsers() async {
    if (mounted) setState(() => usersLoading = true);
    try {
      final query = userQuery.trim();
      final path = '/api/admin/users?page=$userPage&limit=20' +
          (query.isEmpty ? '' : '&q=' + Uri.encodeQueryComponent(query));
      final result = await api.call('GET', path);
      if (mounted) setState(() {
        users = List<dynamic>.from(result['users'] ?? []);
        userTotal = (result['total'] as num?)?.toInt() ?? users.length;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load users: ' + e.toString())));
    } finally {
      if (mounted) setState(() => usersLoading = false);
    }
  }

  Future<void> loadPayments() async {
    if (mounted) setState(() => paymentsLoading = true);
    try {
      final path = '/api/admin/payments?page=$paymentPage&limit=20' +
          (paymentStatus.isEmpty ? '' : '&status=' + paymentStatus);
      final result = await api.call('GET', path);
      if (mounted) setState(() {
        payments = List<dynamic>.from(result['payments'] ?? []);
        paymentTotal = (result['total'] as num?)?.toInt() ?? payments.length;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load payments: ' + e.toString())));
    } finally {
      if (mounted) setState(() => paymentsLoading = false);
    }
  }

  Future<void> changeStatus(Map<String, dynamic> user) async {
    final id = user['_id']?.toString() ?? user['id']?.toString();
    if (id == null || id.isEmpty) return;
    final current = user['status']?.toString() ?? 'active';
    final next = current == 'active' ? 'suspended' : 'active';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(next == 'suspended' ? 'Suspend account?' : 'Reactivate account?'),
        content: Text((user['email'] ?? user['name'] ?? 'This user').toString() +
            ' will ' + (next == 'suspended' ? 'lose access' : 'regain access') + ' to Chatify.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(next == 'suspended' ? 'Suspend' : 'Reactivate')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.call('PATCH', '/api/admin/users/' + id + '/status', {'status': next});
      await loadOverview();
      await loadUsers();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Account ' + (next == 'active' ? 'reactivated.' : 'suspended.'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Account status was not changed: ' + e.toString())));
    }
  }

  @override
  void initState() {
    super.initState();
    refreshDashboard();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Widget _metric(String label, dynamic value, IconData icon) {
    final shown = value is num ? value.toString() : (value?.toString() ?? '0');
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 21, color: theme.colorScheme.onPrimaryContainer),
          ),
          const Spacer(),
          Text(shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(label, maxLines: 2, style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget _healthPanel(ThemeData theme) {
    final components = (platformStatus['components'] as List?) ?? const [];
    final status = platformStatus['status']?.toString() ?? 'unknown';
    final healthy = status == 'operational';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(healthy ? Icons.health_and_safety_outlined : Icons.warning_amber_rounded,
                color: healthy ? Colors.green.shade700 : theme.colorScheme.tertiary),
            const SizedBox(width: 10),
            Expanded(child: Text('Service health', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
            if (statusLoading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            _statusChip(status.toUpperCase(), healthy ? Colors.green : theme.colorScheme.tertiary),
          ]),
          const SizedBox(height: 8),
          Text(statusError ?? platformStatus['notice']?.toString() ?? 'Checking the public service status endpoint…',
              style: theme.textTheme.bodySmall),
          if (components.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: components.whereType<Map>().map((item) {
              final componentStatus = item['status']?.toString() ?? 'unknown';
              final color = componentStatus == 'operational' ? Colors.green : theme.colorScheme.tertiary;
              return _statusChip('${item['name']}: $componentStatus', color);
            }).toList()),
          ],
        ]),
      ),
    );
  }

  Widget _statusChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Widget _pager({required int page, required int total, required VoidCallback previous, required VoidCallback next}) {
    final pages = total == 0 ? 0 : (total / 20).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Text(total == 0 ? 'No records' : 'Page $page of $pages · $total records'),
        const Spacer(),
        IconButton(tooltip: 'Previous page', onPressed: page > 1 ? previous : null, icon: const Icon(Icons.chevron_left)),
        IconButton(tooltip: 'Next page', onPressed: page < pages ? next : null, icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  Widget _peopleSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('People and access', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('Review account status and verification. Every change is checked by the server.', style: theme.textTheme.bodyMedium),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: TextField(
          controller: searchController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or email', border: OutlineInputBorder()),
          onSubmitted: (value) { userQuery = value; userPage = 1; loadUsers(); },
        )),
        const SizedBox(width: 8),
        IconButton.filledTonal(tooltip: 'Search accounts', onPressed: () { userQuery = searchController.text; userPage = 1; loadUsers(); }, icon: const Icon(Icons.search)),
      ]),
      if (usersLoading) const LinearProgressIndicator(),
      if (!usersLoading && users.isEmpty) const Card(child: ListTile(leading: Icon(Icons.people_outline), title: Text('No accounts found'), subtitle: Text('Try a different name or email.'))),
      ...users.map((item) {
        final user = Map<String, dynamic>.from(item as Map);
        final role = user['role']?.toString() ?? 'user';
        final status = user['status']?.toString() ?? 'active';
        final name = user['name']?.toString() ?? 'Unnamed user';
        return Card(child: ListTile(
          leading: CircleAvatar(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${user['email'] ?? ''}\n${role.toUpperCase()} · ${status.toUpperCase()} · ${user['emailVerified'] == true ? 'Verified' : 'Unverified'}'),
          isThreeLine: true,
          trailing: role == 'admin' ? const Chip(label: Text('Admin')) : PopupMenuButton<String>(
            tooltip: 'Account actions',
            onSelected: (_) => changeStatus(user),
            itemBuilder: (_) => [PopupMenuItem(value: 'toggle', child: Text(status == 'active' ? 'Suspend account' : 'Reactivate account'))],
          ),
        ));
      }),
      _pager(page: userPage, total: userTotal, previous: () { setState(() => userPage--); loadUsers(); }, next: () { setState(() => userPage++); loadUsers(); }),
    ]);
  }

  Widget _paymentsSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Payment operations', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('Monitor transaction states and investigate pending or failed activity.', style: theme.textTheme.bodyMedium),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerLeft, child: DropdownButton<String>(
        value: paymentStatus,
        items: const [
          DropdownMenuItem(value: '', child: Text('All statuses')),
          DropdownMenuItem(value: 'PENDING', child: Text('Pending')),
          DropdownMenuItem(value: 'SUCCESS', child: Text('Successful')),
          DropdownMenuItem(value: 'FAILED', child: Text('Failed')),
          DropdownMenuItem(value: 'CANCELLED', child: Text('Cancelled')),
        ],
        onChanged: (value) { setState(() { paymentStatus = value ?? ''; paymentPage = 1; }); loadPayments(); },
      )),
      if (paymentsLoading) const LinearProgressIndicator(),
      if (!paymentsLoading && payments.isEmpty) const Card(child: ListTile(leading: Icon(Icons.payments_outlined), title: Text('No payments found'), subtitle: Text('There are no transactions for this filter.'))),
      ...payments.map((item) {
        final payment = Map<String, dynamic>.from(item as Map);
        final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
        final status = payment['status']?.toString() ?? 'Unknown';
        final color = status == 'SUCCESS' ? Colors.green : status == 'FAILED' ? theme.colorScheme.error : theme.colorScheme.tertiary;
        return Card(child: ListTile(
          leading: CircleAvatar(backgroundColor: color.withValues(alpha: .1), child: Icon(status == 'SUCCESS' ? Icons.check_circle_outline : status == 'FAILED' ? Icons.error_outline : Icons.payments_outlined, color: color)),
          title: Text(payment['description']?.toString() ?? payment['paymentId']?.toString() ?? 'Payment'),
          subtitle: Text('${payment['provider'] ?? 'Provider'} · $status\n${payment['paymentId'] ?? ''}'),
          isThreeLine: true,
          trailing: Text('KES ${amount.toStringAsFixed(2)}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ));
      }),
      _pager(page: paymentPage, total: paymentTotal, previous: () { setState(() => paymentPage--); loadPayments(); }, next: () { setState(() => paymentPage++); loadPayments(); }),
      const SizedBox(height: 8),
      const Text('A successful payment is recorded only after the provider confirmation is validated.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading && overview.isEmpty) return const Center(child: CircularProgressIndicator());
    if (error != null && overview.isEmpty) return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.admin_panel_settings_outlined, size: 48),
        const SizedBox(height: 12),
        Text('Administrator dashboard could not load', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: loadOverview, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      ]),
    ));
    final money = (overview['successfulPaymentAmount'] as num?)?.toDouble() ?? 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    return RefreshIndicator(
      onRefresh: refreshDashboard,
      child: ListView(
        padding: EdgeInsets.fromLTRB(screenWidth > 900 ? 32 : 16, 20, screenWidth > 900 ? 32 : 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.secondary], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(children: [
              const CircleAvatar(radius: 26, backgroundColor: Colors.white24, child: Icon(Icons.space_dashboard_rounded, color: Colors.white, size: 28)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Chatify Control Center', style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Communication, business activity, accounts and payment operations.', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: .9))),
                if (refreshedAt != null) ...[
                  const SizedBox(height: 8),
                  Text('Updated ${TimeOfDay.fromDateTime(refreshedAt!).format(context)}', style: theme.textTheme.labelSmall?.copyWith(color: Colors.white70)),
                ],
              ])),
              IconButton(tooltip: 'Refresh control center', onPressed: refreshDashboard, color: Colors.white, icon: const Icon(Icons.refresh_rounded)),
            ]),
          ),
          const SizedBox(height: 14),
          _healthPanel(theme),
          const SizedBox(height: 14),
          SegmentedButton<_AdminSection>(
            segments: const [
              ButtonSegment(value: _AdminSection.overview, label: Text('Overview'), icon: Icon(Icons.dashboard_outlined)),
              ButtonSegment(value: _AdminSection.people, label: Text('People'), icon: Icon(Icons.people_outline)),
              ButtonSegment(value: _AdminSection.payments, label: Text('Payments'), icon: Icon(Icons.payments_outlined)),
            ],
            selected: {section},
            onSelectionChanged: (value) {
              setState(() => section = value.first);
              if (section == _AdminSection.people && users.isEmpty) loadUsers();
              if (section == _AdminSection.payments && payments.isEmpty) loadPayments();
            },
          ),
          const SizedBox(height: 18),
          if (section == _AdminSection.overview) ...[
            Text('Platform snapshot', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Live counts from Chatify records. “Active” means an enabled account, not an online presence.', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: screenWidth > 1100 ? 4 : screenWidth > 700 ? 3 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: screenWidth > 700 ? 1.4 : 1.2,
              children: [
                _metric('Accounts', overview['totalUsers'], Icons.people_alt_outlined),
                _metric('Enabled accounts', overview['activeUsers'], Icons.verified_user_outlined),
                _metric('Verified email', overview['verifiedUsers'], Icons.mark_email_read_outlined),
                _metric('Businesses', overview['totalBusinesses'], Icons.business_outlined),
                _metric('Business customers', overview['businessCustomers'], Icons.groups_2_outlined),
                _metric('Published catalogue items', overview['catalogItems'], Icons.inventory_2_outlined),
                _metric('Conversations', overview['totalConversations'], Icons.forum_outlined),
                _metric('Messages', overview['totalMessages'], Icons.chat_bubble_outline),
                _metric('Saved memories', overview['totalMemories'], Icons.auto_awesome_outlined),
                _metric('Open business cases', overview['openCases'], Icons.support_agent_outlined),
                _metric('Pending payments', overview['pendingPayments'], Icons.hourglass_top),
                _metric('Failed payments', overview['failedPayments'], Icons.error_outline),
              ],
            ),
            const SizedBox(height: 12),
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Last 24 hours', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Wrap(spacing: 10, runSpacing: 8, children: [
                  Chip(avatar: const Icon(Icons.person_add_alt_1, size: 18), label: Text('${overview['newUsers24h'] ?? 0} new accounts')),
                  Chip(avatar: const Icon(Icons.forum_outlined, size: 18), label: Text('${overview['newMessages24h'] ?? 0} messages')),
                  Chip(avatar: const Icon(Icons.add_business_outlined, size: 18), label: Text('${overview['newBusinesses24h'] ?? 0} new businesses')),
                ]),
              ]),
            )),
            Card(child: ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Recorded successful payment volume'),
              subtitle: const Text('Gross confirmed transaction volume; it is not revenue or net profit.'),
              trailing: Text('KES ${money.toStringAsFixed(2)}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            )),
            const SizedBox(height: 12),
            Card(child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Protected operations'),
              subtitle: const Text('Account actions and platform data are authorized by the API for administrator accounts.'),
              trailing: const Icon(Icons.lock_outline),
            )),
          ] else if (section == _AdminSection.people) ...[
            _peopleSection(theme),
          ] else ...[
            _paymentsSection(theme),
          ],
        ],
      ),
    );
  }
}

// Return the other participant's HTTPS profile image for a direct chat. Group chats
// intentionally use their title initial until a dedicated group image is configured.
String? _conversationProfileImage(dynamic conversation, dynamic currentUser) {
  // Only direct chats use a participant's profile photo. Group imagery is a
  // separate conversation-level field and must never inherit a member's avatar.
  if (conversation is! Map ||
      conversation['type'] != 'direct' ||
      conversation['participants'] is! List) return null;
  final currentId = currentUser is Map
      ? (currentUser['id'] ?? currentUser['_id'])?.toString()
      : null;
  for (final person in (conversation['participants'] as List).whereType<Map>()) {
    final personId = (person['_id'] ?? person['id'])?.toString();
    if (currentId != null && personId == currentId) continue;
    final image = person['profileImage'];
    if (image is String && image.startsWith('https://')) return image;
  }
  return null;
}

String? _conversationGroupImage(dynamic conversation) {
  if (conversation is! Map || conversation['type'] != 'group') return null;
  final image = conversation['image'];
  return image is String && image.startsWith('https://') ? image : null;
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
  int _lastMessageEventVersion = 0;

  void _onAppStateChanged() {
    final version = app.messageEventVersion;
    if (version == _lastMessageEventVersion) return;
    _lastMessageEventVersion = version;
    if (tab == 0) unawaited(loadChats());
  }

  @override
  void initState() {
    super.initState();
    _lastMessageEventVersion = app.messageEventVersion;
    app.addListener(_onAppStateChanged);
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
        title: Text(
            'Delete ${ids.length} conversation${ids.length == 1 ? '' : 's'}?'),
        content: Text(
            'This removes the selected conversation${ids.length == 1 ? '' : 's'} from your chat list only. Other participants keep their copies. A new message can make a conversation appear again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete for me')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deletedIds = <String>{};
    try {
      // The API caps each batch at 100 IDs. Chunk large selections so
      // Select all still works for accounts with hundreds of conversations.
      for (var offset = 0; offset < ids.length; offset += 100) {
        final batch = ids.skip(offset).take(100).toList();
        await app.api.call(
            'POST', '/api/conversations/delete', {'conversationIds': batch});
        deletedIds.addAll(batch);
      }
      if (mounted) {
        setState(() {
          chats.removeWhere((c) => c is Map && deletedIds.contains(c['_id']?.toString()));
          selectedConversationIds.clear();
          selectingChats = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${deletedIds.length} conversation${deletedIds.length == 1 ? '' : 's'} deleted from your chat list.')));
      }
    } catch (error) {
      // Preserve the successful part of a large batch operation and leave only
      // the remaining conversations selected so the user can retry safely.
      if (mounted) {
        setState(() {
          chats.removeWhere((c) => c is Map && deletedIds.contains(c['_id']?.toString()));
          selectedConversationIds.removeAll(deletedIds);
          if (selectedConversationIds.isEmpty) selectingChats = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(deletedIds.isEmpty
                ? error.toString()
                : 'Deleted ' + deletedIds.length.toString() +
                    ' conversations. Some remaining items could not be deleted: ' + error.toString())));
      }
    }
  }

  Future<void> loadChats() async {
    // Keep the current list visible while refreshing so a slow/waking API does
    // not replace usable content with a full-screen spinner.
    if (chats.isEmpty) setState(() => loading = true);
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
    if (memories.isEmpty) setState(() => memoriesLoading = true);
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
    final isAdmin = context.watch<AppState>().user?['role'] == 'admin';
    final titles = [
      'Chats',
      'Business',
      'Memories',
      'Contacts',
      'Profile',
      'Stores',
      if (isAdmin) 'Admin'
    ];
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
          IconButton(tooltip: 'Pay a merchant by QR', icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MerchantQrScannerPage()))),
          if (tab == 0 && selectingChats) ...[
            IconButton(
                tooltip: 'Select all',
                icon: const Icon(Icons.select_all),
                onPressed: () => setState(() {
                      selectedConversationIds
                        ..clear()
                        ..addAll(chats
                            .whereType<Map>()
                            .map((c) => c['_id'].toString()));
                    })),
            IconButton(
                tooltip: 'Delete selected conversations',
                onPressed: selectedConversationIds.isEmpty
                    ? null
                    : _deleteSelectedConversations,
                icon: const Icon(Icons.delete_outline)),
            IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(() {
                      selectingChats = false;
                      selectedConversationIds.clear();
                    }),
                icon: const Icon(Icons.close)),
          ] else if (tab == 0) ...[
            IconButton(
                tooltip: 'Select conversations',
                onPressed: () => setState(() => selectingChats = true),
                icon: const Icon(Icons.checklist)),
            IconButton(onPressed: loadChats, icon: const Icon(Icons.refresh)),
          ],
          if (tab == 3)
            IconButton(onPressed: _newGroup, icon: const Icon(Icons.group_add)),
        ],
      ),
      body: IndexedStack(index: tab, children: [
        _chats(),
        const BusinessHub(),
        _memories(),
        _contacts(),
        const Profile(),
        const StoreDirectoryPage(),
        if (isAdmin) const AdminDashboard()
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() => tab = i);
          if (i == 0) loadChats();
          if (i == 2) loadMemories();
        },
        destinations: [
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
          // Keep the customer marketplace reachable after sign-in, not only from the welcome page.
          NavigationDestination(
              icon: Icon(Icons.storefront_outlined), label: 'Stores'),
          if (isAdmin)
            const NavigationDestination(
                icon: Icon(Icons.admin_panel_settings_outlined), label: 'Admin'),
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
              : (conversationPeerName(c, app.user) ?? 'Unknown user')
                  .toString();
          final last = c['lastMessage'];
          final preview = last is Map
              ? (last['text'] ?? 'Start chatting').toString()
              : 'Start chatting';
          final id = c['_id']?.toString() ?? '';
          final selected = selectedConversationIds.contains(id);
          return ListTile(
            leading: selectingChats
                ? Checkbox(
                    value: selected,
                    onChanged: (_) => _toggleConversationSelection(id))
                : CircleAvatar(
                    // A group can only display its own group image. Never fall
                    // back to a member's personal profile photo for group chats.
                    foregroundImage: (() {
                      final image = c['type'] == 'group'
                          ? _conversationGroupImage(c)
                          : _conversationProfileImage(c, app.user);
                      return image == null ? null : NetworkImage(image);
                    })(),
                    child: Text(title.isEmpty ? '?' : title[0].toUpperCase())),
            title: Text(title),
            subtitle: Text(preview),
            selected: selected,
            onLongPress: () {
              if (!selectingChats) setState(() => selectingChats = true);
              _toggleConversationSelection(id);
            },
            onTap: () {
              if (selectingChats) {
                _toggleConversationSelection(id);
                return;
              }
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
      if (mounted) {
        setState(
            () => savedContacts = List<dynamic>.from(result['contacts'] ?? []));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not load contacts: $error')));
      }
    } finally {
      if (mounted) setState(() => contactsLoading = false);
    }
  }

  @override
  void dispose() {
    app.removeListener(_onAppStateChanged);
    _phoneSearchDebounce?.cancel();
    super.dispose();
  }

  Future<void> searchPhone([String? query]) async {
    final value = (query ?? phoneQuery).trim();
    if (query != null) phoneQuery = query;
    if (value.replaceAll(RegExp(r'\D'), '').length < 3) {
      if (mounted) {
        setState(() {
          phoneResults = [];
          phoneSearching = false;
        });
      }
      return;
    }
    setState(() => phoneSearching = true);
    try {
      final result = await app.api.call(
          'GET', '/api/contacts/search?q=${Uri.encodeQueryComponent(value)}');
      if (mounted && phoneQuery.trim() == value) {
        setState(
            () => phoneResults = List<dynamic>.from(result['users'] ?? []));
      }
    } catch (error) {
      if (mounted && phoneQuery.trim() == value) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && phoneQuery.trim() == value) {
        setState(() => phoneSearching = false);
      }
    }
  }

  Future<void> savePhoneContact(String phone) async {
    try {
      await app.api.call('POST', '/api/contacts', {'phone': phone});
      await loadSavedContacts();
      if (mounted) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> removeSavedContact(Map<String, dynamic> contact) async {
    try {
      await app.api.call('DELETE', '/api/contacts/${contact['id']}');
      await loadSavedContacts();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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
            child: Text(
                'No accounts match that number yet. Keep typing or check the digits.'),
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
                  foregroundImage: (person['profileImage'] is String &&
                          (person['profileImage'] as String).startsWith('https://'))
                      ? NetworkImage(person['profileImage'] as String)
                      : null,
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
                          foregroundImage: (contact['profileImage'] is String &&
                                  (contact['profileImage'] as String).startsWith('https://'))
                              ? NetworkImage(contact['profileImage'] as String)
                              : null,
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
            // Dismissible requires the item to leave the backing list immediately;
            // otherwise Flutter can report that a dismissed widget is still in the tree.
            if (mounted) {
              setState(() {
                memories.removeWhere((item) =>
                    item is Map &&
                    item['_id']?.toString() == memory['_id']?.toString());
              });
            }
            try {
              await app.api.call('DELETE', '/api/memories/${memory['_id']}');
            } catch (error) {
              if (!mounted) return;
              await loadMemories();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Could not delete memory: $error')));
            }
          },
          child: Card(
              child: ListTile(
                  title: Text(memory['title']?.toString() ?? 'Memory'),
                  subtitle: Text([
                    if ((memory['personName']?.toString() ?? '').trim().isNotEmpty)
                      'About ${memory['personName']}',
                    memory['description']?.toString() ?? '',
                  ].where((part) => part.trim().isNotEmpty).join(' · ')),
                  trailing: IconButton(
                    tooltip: 'Delete saved memory',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      try {
                        await app.api.call(
                            'DELETE', '/api/memories/${memory['_id']}');
                        if (!mounted) return;
                        setState(() {
                          memories.removeWhere((item) =>
                              item is Map &&
                              item['_id']?.toString() ==
                                  memory['_id']?.toString());
                        });
                      } catch (error) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Could not delete memory: $error')),
                        );
                      }
                    },
                  )),
        ));
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
        // After the STK prompt is requested, move to payment history so the
        // user can follow the server-confirmed payment status without guessing.
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const PaymentHistory(),
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
    final baseAmount = (payment['baseAmount'] as num?)?.toInt() ?? (payment['amount'] as num?)?.toInt() ?? 0;
    final platformFee = (payment['platformFee'] as num?)?.toInt() ?? 0;
    final totalAmount = (payment['totalAmount'] as num?)?.toInt() ?? baseAmount + platformFee;
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
              title:
                  Text(payment['description']?.toString() ?? 'M-Pesa payment'),
              subtitle: Text(
                platformFee > 0
                    ? 'Base KSh $baseAmount + platform fee KSh $platformFee = total KSh $totalAmount · $status · Fee pending settlement${isMock ? ' · Local demo' : ''}'
                    : 'KSh ${payment['amount'] ?? ''} · $status · To ${payment['recipientPhone'] ?? 'recipient'}${isMock ? ' · Local demo' : ''}',
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
                    status == 'PENDING' &&
                    isPayer &&
                    onPay != null)
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
  // Optional editable draft for a product enquiry; it is only sent after the user taps Send.
  final String? initialMessage;
  const Chat({super.key, required this.conversation, this.initialMessage});
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
  bool _savedMemoryMessageIdsLoaded = false;
  bool showClosedPayments = false;
  String expiry = 'NONE';
  String? reply;
  String? typingUser;
  bool searching = false;
  bool sending = false;
  final Set<String> onlineIds = {};
  io.Socket? socket;
  bool loading = true;
  bool _socketConnectedOnce = false;
  String? _socketToken;
  String? loadError;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    if (widget.initialMessage != null && widget.initialMessage!.trim().isNotEmpty) {
      input.text = widget.initialMessage!.trim();
      input.selection = TextSelection.collapsed(offset: input.text.length);
    }
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
    // Password changes rotate JWTs. Rebuild an active chat socket before it retries
    // with the revoked token; initial connection is handled by initState below.
    final currentToken = app.api.token;
    if (_socketToken != null && currentToken != _socketToken) connect();
    final peerId = _directPeerId();
    final shouldBeOnline = peerId != null && app.onlineUserIds.contains(peerId);
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

  String _participantId(dynamic participant) {
    if (participant is Map) {
      return (participant['_id'] ?? participant['id'] ?? '').toString();
    }
    return participant?.toString() ?? '';
  }

  Future<Map<String, dynamic>> _encryptTextPayload(String plaintext) async {
    final senderId = app.user?['id']?.toString() ?? '';
    final ownPublicKey = await app.ensureEncryptionKey();
    final publicKeys = <String, String>{};
    for (final participant in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
      if (participant is! Map) continue;
      final id = _participantId(participant);
      if (id.isEmpty) continue;
      if (id == senderId) {
        publicKeys[id] = ownPublicKey;
        continue;
      }
      final key = participant['encryptionPublicKey']?.toString();
      if (key == null || key.isEmpty) {
        throw StateError('Every conversation member must open the latest Chatify version once to enable encrypted messaging.');
      }
      publicKeys[id] = key;
    }
    return ChatifyE2EE.instance.encryptText(
      senderId: senderId,
      conversationId: widget.conversation['_id'].toString(),
      plaintext: plaintext,
      participantPublicKeys: publicKeys,
      registeredSenderPublicKey: ownPublicKey,
    );
  }

  Future<Map<String, dynamic>> _decryptMessage(Map<String, dynamic> raw) async {
    if (raw['encryptionVersion'] != 1 ||
        raw['encryptedPayload'] is! String ||
        raw['deletedAt'] != null ||
        raw['expiredAt'] != null) {
      return raw;
    }
    final currentId = app.user?['id']?.toString() ?? '';
    final senderId = _participantId(raw['senderId']);
    String? senderPublicKey;
    if (senderId == currentId) {
      senderPublicKey = app.user?['encryptionPublicKey']?.toString();
      if (senderPublicKey == null || senderPublicKey.isEmpty) {
        senderPublicKey = await app.ensureEncryptionKey();
      }
    } else {
      for (final participant in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
        if (participant is Map && _participantId(participant) == senderId) {
          senderPublicKey = participant['encryptionPublicKey']?.toString();
          break;
        }
      }
    }
    try {
      if (senderPublicKey == null || senderPublicKey.isEmpty) {
        throw StateError('The sender public key is unavailable.');
      }
      final clearText = await ChatifyE2EE.instance.decryptText(
        accountId: currentId,
        conversationId: widget.conversation['_id'].toString(),
        senderPublicKey: senderPublicKey,
        encryptedPayload: raw['encryptedPayload'].toString(),
        registeredAccountPublicKey: app.user?['encryptionPublicKey']?.toString(),
      );
      return <String, dynamic>{...raw, 'text': clearText, 'decryptionFailed': false};
    } catch (_) {
      return <String, dynamic>{
        ...raw,
        'text': '🔒 Unable to decrypt this message on this device.',
        'decryptionFailed': true,
      };
    }
  }

  Future<void> load() async {
    try {
      // Fetch conversation metadata and messages together: these are independent
      // requests, and serialising them adds a full network round-trip to every
      // conversation open (especially noticeable on mobile connections).
      final results = await Future.wait([
        app.api.call(
            'GET', '/api/conversations/${widget.conversation['_id']}'),
        app.api.call(
            'GET', '/api/conversations/${widget.conversation['_id']}/messages'),
      ]);
      final detail = results[0];
      widget.conversation
          .addAll(Map<String, dynamic>.from(detail['conversation']));
      final fetched = List<dynamic>.from(results[1]['messages'] ?? []);
      final decryptedFetched = await Future.wait(fetched.map((raw) async {
        if (raw is Map) return _decryptMessage(Map<String, dynamic>.from(raw));
        return raw;
      }));
      if (mounted) {
        setState(() {
          messages = mergeMessages(messages, decryptedFetched);
          loading = false;
          loadError = null;
        });
        _scrollToLatestMessage();
        // Inspect recent text messages automatically; users do not need the manual-save menu.
        _scanRecentMessagesForMemory(fetched);
      }

      // Payment history is supplementary. Do not keep the whole conversation
      // behind a spinner while an unrelated payments endpoint responds slowly.
      unawaited(() async {
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
          // Payment history is optional; the chat remains usable without it.
        }
      }());

      // Delivery receipts are also non-blocking; message content is already visible.
      for (final item in fetched) {
        if (item is Map &&
            item['senderId']?.toString() != app.user?['id']?.toString()) {
          unawaited(markReceived(item['_id'].toString()));
        }
      }
    } catch (error) {
      loadError = error.toString();
    }
    if (mounted && loading) {
      setState(() => loading = false);
      _scrollToLatestMessage();
    }
  }

  void connect() {
    socket?.dispose();
    final token = app.api.token;
    _socketToken = token;
    if (token == null || token.isEmpty) return;
    socket = io.io(
      app.api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(999999)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .disableAutoConnect()
          .build(),
    );
    socket!.onConnect((_) {
      socket!.emit('conversation:join', widget.conversation['_id']);
      // A long-idle socket can reconnect after messages were sent on another
      // device. Fetch the durable server history after reconnect to fill gaps.
      if (_socketConnectedOnce) unawaited(load());
      _socketConnectedOnce = true;
    });
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
      if (data is Map &&
          mounted &&
          peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() => onlineIds.add(peerId));
      }
    });
    socket!.on('user:offline', (data) {
      final peerId = _directPeerId();
      if (data is Map &&
          mounted &&
          peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() => onlineIds.remove(peerId));
      }
    });
    socket!.on('message:new', (data) async {
      if (!mounted || data is! Map) return;
      if (data['conversationId']?.toString() ==
          widget.conversation['_id']?.toString()) {
        final incoming = await _decryptMessage(Map<String, dynamic>.from(data));
        if (!mounted) return;
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
      if (!mounted ||
          data is! Map ||
          data['conversationId']?.toString() !=
              widget.conversation['_id']?.toString()) {
        return;
      }
      final index = messages.indexWhere((m) =>
          m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index < 0) return;
      setState(() {
        final copy = Map<String, dynamic>.from(messages[index]);
        copy['deletedAt'] =
            data['deletedAt'] ?? DateTime.now().toIso8601String();
        copy['text'] = '';
        copy['encryptedPayload'] = null;
        copy['encryptionVersion'] = null;
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
          copy['encryptedPayload'] = null;
          copy['encryptionVersion'] = null;
          copy['mediaUrl'] = null;
          messages[index] = copy;
        });
      }
    });
    socket!.on(
        'message:delivered', (data) => updateMessageState(data, 'deliveredTo'));
    socket!.on('message:read', (data) => updateMessageState(data, 'readBy'));
    // Register all listeners before opening the socket so the first incoming
    // event cannot race listener setup on fast connections.
    socket!.connect();
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
    if (text.length > 5000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Messages must be 5,000 characters or fewer.')));
      return;
    }
    _stopTyping();
    setState(() => sending = true);
    try {
      final encrypted = await _encryptTextPayload(text);
      final result = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        ...encrypted,
        'expiryType': expiry,
        'expiresInSeconds': expiry == 'AFTER_TIME' ? 3600 : null,
        'replyTo': reply,
      });
      if (!mounted) return;
      final sent = await _decryptMessage(
          Map<String, dynamic>.from(result['message']));
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
    // This menu is for requesting money from the contact only.
    // Person-to-person "Send Money" is intentionally not offered here.
    final mode = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('M-Pesa'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Send Money to Till'),
              subtitle: const Text('Pay a shop using its Buy Goods Till number'),
              onTap: () => Navigator.pop(dialog, 'till'),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Paybill'),
              subtitle: const Text('Pay a business using its Paybill and account number'),
              onTap: () => Navigator.pop(dialog, 'paybill'),
            ),
            ListTile(
              leading: const Icon(Icons.call_received),
              title: const Text('Receive Money'),
              subtitle: const Text('Request money from this contact'),
              onTap: () => Navigator.pop(dialog, 'receive'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || mode == null) return;

    // Till and Paybill payments are merchant payments, not person-to-person requests.
    // Collect the merchant details and copy them for quick use in the official M-Pesa app.
    if (mode == 'till' || mode == 'paybill') {
      final isTill = mode == 'till';
      // Load only the payment profile belonging to the storefront this chat was opened from.
      // Payment numbers remain editable so a customer can correct an outdated instruction.
      Map<String, dynamic>? merchantPaymentProfile;
      final storefrontSlug = widget.conversation['businessStorefrontSlug']?.toString();
      try {
        Map<String, dynamic>? profileResponse;
        if (storefrontSlug != null && storefrontSlug.isNotEmpty) {
          final result = await app.api.call(
            'GET',
            '/api/storefront/${Uri.encodeComponent(storefrontSlug)}',
          );
          final store = result['storefront'];
          if (store is Map && store['paymentProfile'] is Map) {
            profileResponse = Map<String, dynamic>.from(store['paymentProfile'] as Map);
          }
        } else {
          // For an ordinary direct chat, resolve the other participant's single published
          // storefront. If the seller owns multiple stores, the API asks the customer to
          // open the intended storefront instead of guessing the wrong payment destination.
          final participants = List<dynamic>.from(widget.conversation['participants'] ?? []);
          final currentIds = <String>{
            app.user?['_id']?.toString() ?? '',
            app.user?['id']?.toString() ?? '',
          }..remove('');
          Map? peer;
          for (final raw in participants) {
            if (raw is! Map) continue;
            final id = (raw['_id'] ?? raw['id'] ?? raw['userId'])?.toString() ?? '';
            final nested = raw['user'] is Map ? raw['user'] as Map : null;
            final peerId = id.isNotEmpty ? id : (nested?['_id'] ?? nested?['id'])?.toString() ?? '';
            if (peerId.isNotEmpty && !currentIds.contains(peerId)) {
              peer = raw;
              break;
            }
          }
          final peerId = peer == null
              ? ''
              : ((peer['_id'] ?? peer['id'] ?? peer['userId'])?.toString() ??
                  ((peer['user'] is Map)
                      ? ((peer['user'] as Map)['_id'] ?? (peer['user'] as Map)['id'])?.toString() ?? ''
                      : ''));
          if (peerId.isNotEmpty) {
            final result = await app.api.call(
              'GET',
              '/api/storefront/by-seller/${Uri.encodeComponent(peerId)}/payment-profile',
            );
            if (result['paymentProfile'] is Map) {
              profileResponse = Map<String, dynamic>.from(result['paymentProfile'] as Map);
            }
          }
        }
        merchantPaymentProfile = profileResponse;
      } catch (_) {
        // Payment details can still be entered manually if the storefront is unavailable,
        // the seller has no published store, or multiple stores make the destination ambiguous.
      }
      final businessNumber = TextEditingController(
        text: isTill
            ? (merchantPaymentProfile?['method'] == 'mpesa_till'
                ? (merchantPaymentProfile?['tillNumber']?.toString() ?? '')
                : '')
            : (merchantPaymentProfile?['method'] == 'mpesa_paybill'
                ? (merchantPaymentProfile?['paybillNumber']?.toString() ?? '')
                : ''),
      );
      final accountNumber = TextEditingController(
        text: !isTill && merchantPaymentProfile?['method'] == 'mpesa_paybill'
            ? (merchantPaymentProfile?['accountNumber']?.toString() ?? '')
            : '',
      );
      if (!mounted) return;
      final paymentAmount = TextEditingController();
      final paymentForm = GlobalKey<FormState>();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(isTill ? 'Send Money to Till' : 'Paybill'),
          content: Form(
            key: paymentForm,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: businessNumber,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: isTill ? 'Buy Goods Till number' : 'Paybill business number',
                      helperText: businessNumber.text.isNotEmpty
                          ? 'Loaded from this business; you can edit it'
                          : 'Enter the number provided by the business',
                    ),
                    validator: (value) {
                      final number = (value ?? '').trim();
                      return number.length >= 5 && number.length <= 10 && int.tryParse(number) != null
                          ? null
                          : 'Enter a valid 5–10 digit number';
                    },
                  ),
                  if (!isTill)
                    TextFormField(
                      controller: accountNumber,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Account number'),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? 'Enter the Paybill account number'
                          : null,
                    ),
                  TextFormField(
                    controller: paymentAmount,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Amount (KSh)'),
                    validator: (value) {
                      final amountValue = int.tryParse((value ?? '').trim());
                      return amountValue == null || amountValue < 1 || amountValue > 150000
                          ? 'Enter KSh 1–150,000'
                          : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Chatify copies the payment details for you. In the official M-Pesa app, choose Lipa na M-Pesa and verify the recipient and amount before entering your PIN.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (paymentForm.currentState?.validate() ?? false) {
                  Navigator.pop(dialog, true);
                }
              },
              child: const Text('Copy payment details'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        final details = isTill
            ? 'M-Pesa Buy Goods / Till\nTill number: ${businessNumber.text.trim()}\nAmount: KSh ${paymentAmount.text.trim()}'
            : 'M-Pesa Paybill\nBusiness number: ${businessNumber.text.trim()}\nAccount number: ${accountNumber.text.trim()}\nAmount: KSh ${paymentAmount.text.trim()}';
        await Clipboard.setData(ClipboardData(text: details));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isTill
                ? 'Till payment details copied. Open M-Pesa > Lipa na M-Pesa > Buy Goods.'
                : 'Paybill details copied. Open M-Pesa > Lipa na M-Pesa > Paybill.'),
            duration: const Duration(seconds: 5),
          ));
        }
      }
      businessNumber.dispose();
      accountNumber.dispose();
      paymentAmount.dispose();
      return;
    }

    final me = app.user?['_id']?.toString() ?? app.user?['id']?.toString() ?? '';
    final participants =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
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
    final payerPhone =
        TextEditingController(text: other['phone']?.toString() ?? '');
    final recipientPhone =
        TextEditingController(text: app.user?['phone']?.toString() ?? '');
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
                              helperText:
                                  'Defaults to the other participant’s registered number. You can edit it for this request.'),
                          validator: (v) =>
                              normalizeKenyanPhone(v ?? '') == null
                                  ? 'Enter a valid Kenyan M-Pesa number'
                                  : null),
                      TextFormField(
                          controller: recipientPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Recipient M-Pesa Number',
                              hintText: '0712345678 or 254712345678',
                              helperText:
                                  'Defaults to your registered number. Editing affects this request only.'),
                          validator: (v) =>
                              normalizeKenyanPhone(v ?? '') == null
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
        text: payment['payerPhone']?.toString() ??
            payment['phone']?.toString() ??
            app.user?['phone']?.toString() ??
            '');
    final form = GlobalKey<FormState>();
    final baseAmount = (payment['baseAmount'] as num?)?.toInt() ?? (payment['amount'] as num?)?.toInt() ?? 0;
    final platformFee = (payment['platformFee'] as num?)?.toInt() ?? 0;
    final totalAmount = (payment['totalAmount'] as num?)?.toInt() ?? baseAmount + platformFee;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Review M-Pesa payment'),
              content: Form(
                key: form,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Requested amount: KSh $baseAmount\nPlatform fee (0.5%, rounded up to whole KSh): KSh $platformFee\nTotal charged: KSh $totalAmount', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 10),
                  const Text('The fee is recorded as pending settlement. Chatify does not automatically receive or split the fee yet. This STK payment goes to the configured business shortcode, not directly to a personal recipient.', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 10),
                  TextFormField(
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
                ]),
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
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/initiate', {
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
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/close', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Closed for you. The other person can still see this request.')));
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
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/reopen', {});
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
        title: Text(
            isPayer ? 'Reject M-Pesa request?' : 'Withdraw M-Pesa request?'),
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
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/reject', {});
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
    // Attachments are not covered by the current text-message E2EE protocol.
    // Warn explicitly rather than implying that images have the same protection.
    final acknowledgeRisk = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Image privacy notice'),
        content: const Text('Images and shared image URLs are not end-to-end encrypted yet. The service may be able to access uploaded images or URLs. Do not send sensitive images until attachment encryption is available.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Continue')),
        ],
      ),
    );
    if (!mounted || acknowledgeRisk != true) return;
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
        bytes = Uint8List.fromList(base64Decode(url.substring(comma + 1)));
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
              content: Text(
                  'Image download requested. Check your browser downloads.'),
            ));
          }
          return;
        }

        final response = await http.get(uri).timeout(
              const Duration(seconds: 45),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
              'Image download failed (HTTP ${response.statusCode}).');
        }
        bytes = response.bodyBytes;
        mime = (response.headers['content-type'] ?? '')
            .split(';')
            .first
            .toLowerCase();
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
  Future<void> _scanRecentMessagesForMemory(
      List<dynamic> sourceMessages) async {
    final recent = sourceMessages.whereType<Map>().toList().reversed.take(12);
    for (final raw in recent) {
      if (await _detectMemoryForMessage(Map<String, dynamic>.from(raw))) return;
    }
  }

  String? _memoryPersonNameForMessage(Map<String, dynamic> message) {
    final senderId = _participantId(message['senderId']);
    final currentId = app.user?['id']?.toString() ?? '';
    if (senderId.isEmpty || senderId == currentId) return null;
    for (final participant in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
      if (participant is Map && _participantId(participant) == senderId) {
        final name = participant['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }

  Future<bool> _detectMemoryForMessage(Map<String, dynamic> message) async {
    // Encrypted text is decrypted on this device first; candidate extraction stays local.
    if (message['messageType'] != 'text' ||
        message['deletedAt'] != null ||
        message['expiredAt'] != null ||
        message['text'] is! String) {
      return false;
    }
    final text = (message['text'] as String).trim();
    final id = message['_id']?.toString();
    if (text.isEmpty ||
        id == null ||
        id.isEmpty ||
        _checkedMemoryMessageIds.contains(id) ||
        _dismissedMemoryMessageIds.contains(id) ||
        _savedMemoryMessageIds.contains(id)) {
      return false;
    }
    _checkedMemoryMessageIds.add(id);
    try {
      // Load the user's saved cards before suggesting anything from history.
      // This survives app restarts and prevents an already-saved source message
      // from repeatedly appearing as a new suggestion on another device.
      if (!_savedMemoryMessageIdsLoaded) {
        final saved = List<dynamic>.from(
            (await app.api.call('GET', '/api/memories'))['memories'] ?? []);
        for (final item in saved) {
          if (item is Map && item['sourceMessageId'] != null) {
            _savedMemoryMessageIds.add(item['sourceMessageId'].toString());
          }
        }
        _savedMemoryMessageIdsLoaded = true;
      }
      if (_savedMemoryMessageIds.contains(id)) return false;
      // Do not upload plaintext from an end-to-end encrypted message to the API.
      // Attribution is attached for display here and re-derived by the server when saved.
      final personName = _memoryPersonNameForMessage(message);
      final candidates = extractMemoryCandidatesLocally(text)
          .map((item) => <String, dynamic>{
                ...item,
                if (personName != null) 'personName': personName,
              })
          .toList();
      if (!mounted || candidates.isEmpty) return false;
      // Persist the one-time suggestion claim across app restarts and devices. A deleted card keeps its tombstone, so the source can never be suggested again.
      final seen = await app.api.call('POST', '/api/memories/seen', {
        'conversationId': widget.conversation['_id'],
        'sourceMessageId': id,
      });
      if (seen['alreadySeen'] == true || !mounted) return false;
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
      final savedResult = await app.api.call('POST', '/api/memories', {
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(savedResult['alreadySaved'] == true
              ? 'This Memory Card was already saved.'
              : 'Memory saved to your Memory Cards.')));
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
        content: const Text(
            'This removes the message for everyone in the conversation. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete for everyone')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await app.api.call('DELETE', '/api/messages/$id', {});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages
          .indexWhere((item) => item is Map && item['_id']?.toString() == id);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message deleted for everyone.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> showMessageActions(Map<String, dynamic> message) async {
    final mine = message['senderId']?.toString() == app.user?['id']?.toString();
    final deleted =
        message['deletedAt'] != null || message['expiredAt'] != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Wrap(
          children: [
            if (!deleted) ...[
              ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () => Navigator.pop(sheet, 'reply')),
              ListTile(
                  leading: const Text('❤️', style: TextStyle(fontSize: 22)),
                  title: const Text('React with ❤️'),
                  onTap: () => Navigator.pop(sheet, '❤️')),
              ListTile(
                  leading: const Text('👍', style: TextStyle(fontSize: 22)),
                  title: const Text('React with 👍'),
                  onTap: () => Navigator.pop(sheet, '👍')),
              ListTile(
                  leading: const Text('😂', style: TextStyle(fontSize: 22)),
                  title: const Text('React with 😂'),
                  onTap: () => Navigator.pop(sheet, '😂')),
            ],
            if (mine && !deleted)
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Delete for everyone'),
                  onTap: () => Navigator.pop(sheet, 'delete')),
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
                                            (MediaQuery.sizeOf(context).width *
                                                    0.62)
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
                                          bottomLeft:
                                              Radius.circular(mine ? 18 : 5),
                                          bottomRight:
                                              Radius.circular(mine ? 5 : 18),
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
                                                  final original =
                                                      findReplyTarget(messages,
                                                          message['replyTo']);
                                                  // A non-null empty map keeps preview rendering null-safe
                                                  // while the unavailable flag preserves deleted-message semantics.
                                                  final originalMap =
                                                      original ??
                                                          <String, dynamic>{};
                                                  final unavailable =
                                                      original == null ||
                                                          originalMap[
                                                                  'deletedAt'] !=
                                                              null ||
                                                          originalMap[
                                                                  'expiredAt'] !=
                                                              null;
                                                  final originalSender =
                                                      originalMap['senderId']
                                                                  ?.toString() ==
                                                              app.user?['id']
                                                                  ?.toString()
                                                          ? 'You'
                                                          : 'Message';
                                                  final preview = unavailable
                                                      ? 'Original message unavailable'
                                                      : (originalMap['text'] ??
                                                              '[media]')
                                                          .toString();
                                                  return Container(
                                                    width: double.infinity,
                                                    margin:
                                                        const EdgeInsets.only(
                                                            bottom: 7),
                                                    padding:
                                                        const EdgeInsets.all(8),
                                                    decoration: BoxDecoration(
                                                      color: mine
                                                          ? const Color(
                                                              0x33404040)
                                                          : const Color(
                                                              0xFFF0EFFF),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      border: Border(
                                                          left: BorderSide(
                                                        color: mine
                                                            ? Colors.white70
                                                            : const Color(
                                                                0xFF4F46E5),
                                                        width: 3,
                                                      )),
                                                    ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                            'Replying to $originalSender',
                                                            style: TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                fontSize: 11,
                                                                color: mine
                                                                    ? Colors
                                                                        .white
                                                                    : const Color(
                                                                        0xFF4F46E5))),
                                                        Text(preview,
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                                fontSize: 12,
                                                                color: mine
                                                                    ? Colors
                                                                        .white
                                                                    : const Color(
                                                                        0xFF39445A))),
                                                      ],
                                                    ),
                                                  );
                                                }),
                                              if (mine &&
                                                  message['deletedAt'] ==
                                                      null &&
                                                  message['expiredAt'] == null)
                                                Align(
                                                  widthFactor: 1,
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child:
                                                      PopupMenuButton<String>(
                                                    tooltip: 'Message options',
                                                    padding: EdgeInsets.zero,
                                                    constraints:
                                                        const BoxConstraints(
                                                      minWidth: 44,
                                                      minHeight: 44,
                                                    ),
                                                    iconSize: 20,
                                                    icon: Icon(
                                                      Icons.more_horiz,
                                                      color: mine
                                                          ? Colors.white
                                                          : const Color(
                                                              0xFF536078),
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
                                                              Icons
                                                                  .delete_outline,
                                                              color: Color(
                                                                  0xFFDC2626),
                                                              size: 20,
                                                            ),
                                                            SizedBox(width: 10),
                                                            Text(
                                                                'Delete for everyone'),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              if (message['deletedAt'] == null &&
                                                  message['expiredAt'] ==
                                                      null &&
                                                  message['messageType'] ==
                                                      'image' &&
                                                  message['mediaUrl'] != null)
                                                renderImage(message['mediaUrl']
                                                    .toString())
                                              else
                                                Text(text),
                                              if (message[
                                                          'deletedAt'] ==
                                                      null &&
                                                  message['reactions']
                                                      is List &&
                                                  (message['reactions'] as List)
                                                      .isNotEmpty)
                                                Text((message['reactions']
                                                        as List)
                                                    .map((r) => r['emoji'])
                                                    .join(' ')),
                                              if (mine &&
                                                  message['deliveredTo']
                                                      is List &&
                                                  (message['deliveredTo']
                                                              as List)
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
                                                    style: const TextStyle(
                                                        fontSize: 10))
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
                          onPressed: savingMemorySuggestion
                              ? null
                              : _dismissMemorySuggestions,
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
                                  Text(
                                      suggestion['title']?.toString() ??
                                          'Memory',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  if ((suggestion['personName']?.toString() ?? '')
                                  .trim().isNotEmpty)
                                Text(
                                  'About ${suggestion['personName']}',
                                  style: const TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              Text(suggestion['description']?.toString() ??
                                  ''),
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
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Text('Save'),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: savingMemorySuggestion
                            ? null
                            : _dismissMemorySuggestions,
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
                originalMap['deletedAt'] != null ||
                originalMap['expiredAt'] != null;
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
                border: const Border(
                    left: BorderSide(color: Color(0xFF4F46E5), width: 3)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.reply, color: Color(0xFF4F46E5), size: 19),
                const SizedBox(width: 8),
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Replying to $originalSender',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: Color(0xFF4F46E5))),
                    Text(originalText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF39445A))),
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

  Future<void> chooseProfilePicture() async {
    final api = context.read<AppState>().api;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > 10 * 1024 * 1024) {
        throw Exception('Choose an image smaller than 10 MB.');
      }
      final path = picked.path.toLowerCase();
      final mimeType = path.endsWith('.png')
          ? 'image/png'
          : path.endsWith('.webp')
              ? 'image/webp'
              : 'image/jpeg';
      if (!mounted) return;
      final upload = await api.call('POST', '/api/media', {
        'data': base64Encode(bytes),
        'mimeType': mimeType,
      });
      final mediaUrl = upload['mediaUrl']?.toString();
      if (mediaUrl == null || !mediaUrl.startsWith('https://')) {
        throw Exception('Image upload did not return a secure image URL.');
      }
      final saved = await api.call(
          'PATCH', '/api/users/me', {'profileImage': mediaUrl});
      if (!mounted) return;
      context.read<AppState>().updateCurrentUser(
            Map<String, dynamic>.from(saved['user']),
          );
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not update picture: $error')));
      }
    }
  }

  Future<void> saveDefaultPhone() async {
    final normalized = normalizeKenyanPhone(phone.text);
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Enter a valid Kenyan M-Pesa number, e.g. 0712345678')));
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
          content: Text(
              'Default M-Pesa number saved. Payment requests will use it automatically.')));
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
                            final appState = context.read<AppState>();
                            final passwordResult = await appState.api.call(
                                'POST', '/api/auth/change-password', {
                              'currentPassword': current.text,
                              'newPassword': next.text
                            });
                            if (passwordResult['token'] is String) {
                              await appState.api.saveToken(passwordResult['token'] as String);
                              appState.refreshRealtimeAuthentication();
                            }
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
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final profileImage = app.user?['profileImage']?.toString();
    return ListView(padding: const EdgeInsets.all(18), children: [
        Center(
          child: Column(children: [
            CircleAvatar(
              radius: 42,
              foregroundImage: profileImage != null &&
                      profileImage.startsWith('https://')
                  ? NetworkImage(profileImage)
                  : null,
              // Keep the placeholder beneath the foreground image so it remains
              // visible when a stored URL is expired, blocked, or unreachable.
              child: const Icon(Icons.person_outline, size: 42),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: chooseProfilePicture,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Change profile picture'),
            ),
          ]),
        ),
        SwitchListTile(
          value: app.themeMode == ThemeMode.dark,
          onChanged: app.setDarkMode,
          secondary: Icon(app.themeMode == ThemeMode.dark
              ? Icons.dark_mode_outlined
              : Icons.light_mode_outlined),
          title: const Text('Dark mode'),
          subtitle: const Text('Use a darker, low-glare appearance'),
        ),
        TextField(
            controller: name,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        const Text('Default M-Pesa number',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text(
            'Set this for your existing account. Chatify will prefill it when you send or receive payment requests. You can still change either number on an individual request.'),
        const SizedBox(height: 10),
        TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: 'M-Pesa phone number',
                hintText: '0712345678 or 254712345678',
                helperText: (context
                            .watch<AppState>()
                            .user?['phone']
                            ?.toString()
                            .isNotEmpty ??
                        false)
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
}

/// Customer-facing public marketplace for discovering businesses and their published catalogue.
class StoreDirectoryPage extends StatefulWidget {
  const StoreDirectoryPage({super.key});
  @override
  State<StoreDirectoryPage> createState() => _StoreDirectoryPageState();
}

class _StoreDirectoryPageState extends State<StoreDirectoryPage> {
  final search = TextEditingController();
  final location = TextEditingController();
  final category = TextEditingController();
  List<dynamic> stores = [], products = [];
  bool loading = true, showingProducts = false;
  String country = 'KE';
  String? error;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    loadResults();
  }

  @override
  void dispose() {
    search.dispose();
    location.dispose();
    category.dispose();
    super.dispose();
  }

  Future<void> loadResults() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final parameters = <String, String>{
        if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
        if (category.text.trim().isNotEmpty) 'category': category.text.trim(),
        if (country.isNotEmpty) 'country': country,
        if (location.text.trim().isNotEmpty) 'location': location.text.trim(),
        'page': '1',
        'pageSize': '50',
      };
      final endpoint =
          showingProducts ? '/api/marketplace/products' : '/api/marketplace';
      final result = await app.api
          .call('GET', '$endpoint?${Uri(queryParameters: parameters).query}');
      if (!mounted) return;
      setState(() {
        if (showingProducts) {
          products = List<dynamic>.from(result['products'] ?? []);
        } else {
          stores = List<dynamic>.from(result['businesses'] ?? []);
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = showingProducts ? products : stores;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore marketplace'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PaymentHistory()),
            ),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Payments'),
          ),
          IconButton(
              tooltip: 'Refresh marketplace',
              onPressed: loadResults,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.storefront_outlined),
                  label: Text('Businesses')),
              ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.shopping_bag_outlined),
                  label: Text('Products')),
            ],
            selected: {showingProducts},
            onSelectionChanged: (selection) {
              setState(() => showingProducts = selection.first);
              loadResults();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => loadResults(),
            decoration: InputDecoration(
              hintText: showingProducts
                  ? 'Search products and services'
                  : 'Business name or @handle (e.g. @prime-cafe)',
              prefixIcon: const Icon(Icons.search),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: category,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => loadResults(),
                decoration: InputDecoration(
                  labelText: 'Category',
                  hintText: 'e.g. retail',
                  prefixIcon: const Icon(Icons.category_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 105,
              child: DropdownButtonFormField<String>(
                initialValue: country,
                decoration: InputDecoration(
                  labelText: 'Country',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                ),
                items: const [
                  DropdownMenuItem(value: 'KE', child: Text('Kenya')),
                  DropdownMenuItem(value: 'UG', child: Text('Uganda')),
                  DropdownMenuItem(value: 'TZ', child: Text('Tanzania')),
                  DropdownMenuItem(value: 'RW', child: Text('Rwanda')),
                  DropdownMenuItem(value: 'US', child: Text('USA')),
                  DropdownMenuItem(value: 'GB', child: Text('UK')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => country = value);
                  loadResults();
                },
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: location,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => loadResults(),
                decoration: InputDecoration(
                  labelText: 'Town or branch',
                  hintText: 'e.g. Nairobi',
                  prefixIcon: const Icon(Icons.location_on_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: loadResults,
                icon: const Icon(Icons.tune),
                label: const Text('Filter')),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: loadResults,
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                    ? ListView(children: [
                        const SizedBox(height: 90),
                        const Icon(Icons.cloud_off_outlined, size: 48),
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(error!, textAlign: TextAlign.center)),
                        Center(
                            child: FilledButton(
                                onPressed: loadResults,
                                child: const Text('Try again'))),
                      ])
                    : entries.isEmpty
                        ? ListView(children: [
                            const SizedBox(height: 80),
                            const Icon(Icons.storefront_outlined,
                                size: 56, color: Color(0xFF77758B)),
                            const SizedBox(height: 12),
                            Center(
                                child: Text(
                              showingProducts
                                  ? 'No products match these filters.'
                                  : 'No businesses match these filters.',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            )),
                            const SizedBox(height: 6),
                            const Center(
                                child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 28),
                              child: Text(
                                  'Published businesses and active catalogue items appear here. Clear a filter or try another search.',
                                  textAlign: TextAlign.center),
                            )),
                          ])
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: entries.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final entry = Map<String, dynamic>.from(
                                  entries[index] as Map);
                              if (showingProducts) {
                                final business = entry['business'] is Map
                                    ? Map<String, dynamic>.from(
                                        entry['business'] as Map)
                                    : <String, dynamic>{};
                                final images = entry['images'] is List
                                    ? List<dynamic>.from(entry['images'])
                                    : <dynamic>[];
                                final image = images.isNotEmpty
                                    ? images.first.toString()
                                    : '';
                                final currency =
                                    entry['currency']?.toString() ?? 'KES';
                                final price = entry['price']?.toString() ?? '—';
                                return Card(
                                  clipBehavior: Clip.antiAlias,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.all(12),
                                    leading: CircleAvatar(
                                      radius: 28,
                                      backgroundColor: const Color(0xFFEDEBFF),
                                      backgroundImage:
                                          image.startsWith('https://')
                                              ? NetworkImage(image)
                                              : null,
                                      child: image.startsWith('https://')
                                          ? null
                                          : const Icon(
                                              Icons.inventory_2_outlined,
                                              color: Color(0xFF5548E8)),
                                    ),
                                    title: Text(
                                        entry['name']?.toString() ??
                                            'Product or service',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    subtitle: Text(
                                        '${business['name'] ?? 'Chatify business'} · ${entry['category'] ?? 'General'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                    trailing: Text('$currency $price',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    onTap: business['slug'] == null
                                        ? null
                                        : () => Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      StorefrontPage(
                                                          slug: business['slug']
                                                              .toString())),
                                            ),
                                  ),
                                );
                              }
                              final name = entry['name']?.toString() ??
                                  'Chatify business';
                              final logo = entry['logo']?.toString() ?? '';
                              final count =
                                  entry['itemCount']?.toString() ?? '0';
                              final industry = entry['industry']
                                      ?.toString()
                                      .replaceAll('_', ' ') ??
                                  '';
                              return Card(
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(12),
                                  leading: CircleAvatar(
                                    radius: 28,
                                    backgroundColor: const Color(0xFFEDEBFF),
                                    backgroundImage: logo.startsWith('https://')
                                        ? NetworkImage(logo)
                                        : null,
                                    child: logo.startsWith('https://')
                                        ? null
                                        : const Icon(Icons.storefront_rounded,
                                            color: Color(0xFF5548E8)),
                                  ),
                                  title: Text(name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                        [
                                          if (industry.isNotEmpty)
                                            industry[0].toUpperCase() +
                                                industry.substring(1),
                                          '$count product/service(s)',
                                          if ((entry['country']?.toString() ??
                                                  '')
                                              .isNotEmpty)
                                            entry['country'].toString(),
                                          if ((entry['description']
                                                      ?.toString() ??
                                                  '')
                                              .isNotEmpty)
                                            entry['description'].toString(),
                                        ].join(' · '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  trailing: const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 16),
                                  onTap: () => Navigator.of(context)
                                      .push(MaterialPageRoute<void>(
                                    builder: (_) => StorefrontPage(
                                        slug: entry['slug'].toString()),
                                  )),
                                ),
                              );
                            },
                          ),
          ),
        ),
      ]),
    );
  }
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
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await app.api
          .call('GET', '/api/storefront/${Uri.encodeComponent(widget.slug)}');
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
        return sum +
            (double.tryParse(item['price']?.toString() ?? '') ?? 0) *
                (cart[item['_id']?.toString()] ?? 0);
      });

  void addProduct(Map<String, dynamic> item) {
    final id = item['_id']?.toString();
    if (id == null) return;
    final current = cart[id] ?? 0;
    final stock = int.tryParse(item['stock']?.toString() ?? '') ?? 0;
    if (stock > 0 && current >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('You have selected all available stock for this product.')));
      return;
    }
    setState(() => cart[id] = current + 1);
  }

  // Open a private customer/seller conversation without exposing the seller's contact details.
  // The normal Chat screen retains end-to-end encryption and existing payment tools.
  Future<void> chatWithSeller({Map<String, dynamic>? item}) async {
    final sellerId = storefront['sellerUserId']?.toString() ?? '';
    if (sellerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This seller has not enabled direct Chatify messaging yet.')));
      return;
    }
    if (app.user == null) {
      final shouldSignIn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Chat with seller'),
          content: const Text('Sign in to discuss products, delivery and payment securely with this seller.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Sign in')),
          ],
        ),
      );
      if (shouldSignIn == true && mounted) app.openAuth();
      return;
    }
    final currentUserId = app.user?['_id']?.toString() ?? app.user?['id']?.toString() ?? '';
    if (sellerId == currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Open this store using a customer account to contact the seller.')));
      return;
    }
    try {
      final result = await app.api.call('POST', '/api/conversations/direct', {'userId': sellerId});
      final conversation = Map<String, dynamic>.from(result['conversation'] ?? {});
      // Preserve the storefront context locally so chat payment forms can load this exact
      // merchant's public Till/Paybill instructions instead of guessing by seller name.
      final storefrontSlug = storefront['slug']?.toString();
      if (storefrontSlug != null && storefrontSlug.isNotEmpty) {
        conversation['businessStorefrontSlug'] = storefrontSlug;
      }
      if (!mounted || conversation.isEmpty) return;
      if (item != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Chat opened. Ask about ' + (item['name']?.toString() ?? 'this item') + '; secure M-Pesa checkout is available on this storefront.'),
        ));
      }
      final draft = item == null
          ? null
          : 'Hi, I am interested in ' +
              (item['name']?.toString() ?? 'this item') +
              ' from ' +
              (storefront['name']?.toString() ?? 'your store') +
              '. Could you share availability, delivery options and the best way to pay?';
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Chat(conversation: conversation, initialMessage: draft),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open seller chat: $e')),
      );
    }
  }

  Future<void> showProduct(Map<String, dynamic> item) async {
    final id = item['_id']?.toString() ?? '';
    final image =
        (item['images'] is List && (item['images'] as List).isNotEmpty)
            ? (item['images'] as List).first.toString()
            : '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item['name']?.toString() ?? 'Product'),
        content: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image.startsWith('https://'))
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(image,
                    height: 170,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            const SizedBox(height: 8),
            Text('KSh ${item['price'] ?? '—'}',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(item['description']?.toString() ??
                'No product description yet.'),
            if ((item['category']?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Chip(label: Text(item['category'].toString())),
              ),
          ],
        )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              chatWithSeller(item: item);
            },
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Ask seller'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              addProduct(item);
            },
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
          content: const Text(
              'You can browse products without an account. Sign in or create an account to place an order and receive the secure M-Pesa payment prompt.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (signIn == true && mounted) app.openAuth(register: true);
      return;
    }
    if (normalizeKenyanPhone(phone.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid Kenyan M-Pesa phone number.')));
      return;
    }
    setState(() {
      checkingOut = true;
      notice = null;
      error = null;
    });
    try {
      final result = await app.api.call('POST',
          '/api/storefront/${Uri.encodeComponent(widget.slug)}/checkout', {
        'phone': phone.text.trim(),
        'items': cart.entries
            .map((entry) => {'itemId': entry.key, 'quantity': entry.value})
            .toList(),
      });
      final payment = Map<String, dynamic>.from(result['payment'] ?? {});
      final id = payment['paymentId']?.toString();
      if (id == null || id.isEmpty) {
        throw const FormatException(
            'Order was created but no payment reference was returned.');
      }
      final baseAmount = (payment['baseAmount'] as num?)?.toInt() ?? (payment['amount'] as num?)?.toInt() ?? 0;
      final platformFee = (payment['platformFee'] as num?)?.toInt() ?? 0;
      final totalAmount = (payment['totalAmount'] as num?)?.toInt() ?? baseAmount + platformFee;
      final consent = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm checkout total'),
        content: Text('Order subtotal: KSh $baseAmount\nChatify platform fee (0.5%, rounded up to whole KSh): KSh $platformFee\nTotal M-Pesa charge: KSh $totalAmount\n\nThe platform fee is pending settlement and is not automatically transferred to Chatify yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue to M-Pesa')),
        ],
      ));
      if (consent != true) {
        if (mounted) setState(() { paymentId = id; notice = 'Order saved, but no M-Pesa prompt was sent. You can refresh this payment or contact the store.'; });
        return;
      }
      if (mounted) {
        setState(() {
          paymentId = id;
          notice = 'Order created. Requesting M-Pesa payment prompt…';
        });
      }
      final initiated = await app.api.call(
          'POST',
          '/api/payments/${Uri.encodeComponent(id)}/initiate',
          {'phone': phone.text.trim()});
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
      final result =
          await app.api.call('GET', '/api/payments/${Uri.encodeComponent(id)}');
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
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (error != null && storefront.isEmpty) {
      return Scaffold(
          appBar: AppBar(title: const Text('Storefront')),
          body: Center(
              child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
        actions: [
          TextButton.icon(
            onPressed: () => chatWithSeller(),
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Chat seller'),
          ),
          // Keep payment history visible from the customer storefront, not hidden behind an icon-only menu.
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PaymentHistory()),
            ),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Payments'),
          ),
          IconButton(
              tooltip: 'Refresh products',
              onPressed: loadStore,
              icon: const Icon(Icons.refresh)),
        ],
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
                gradient: const LinearGradient(
                    colors: [Color(0xFF292C57), Color(0xFF5548E8)]),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.storefront_rounded,
                        color: Colors.white, size: 30),
                    const SizedBox(height: 10),
                    Text(storefront['name']?.toString() ?? 'Shop',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 5),
                    Text(
                        storefront['description']?.toString() ??
                            'Browse products, add what you need to your cart, and pay securely with M-Pesa.',
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 10),
                    const Text('Secure checkout · M-Pesa',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                    if ((storefront['sellerMpesaPhone']?.toString() ?? '')
                        .isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Seller M-Pesa: ${storefront['sellerMpesaPhone']}',
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ]),
            ),
            const SizedBox(height: 16),
            Text('Products',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (products.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('This store has no active products yet.',
                    textAlign: TextAlign.center),
              ),
            ...products.whereType<Map>().map((raw) {
              final item = Map<String, dynamic>.from(raw);
              final id = item['_id']?.toString() ?? '';
              final image = (item['images'] is List &&
                      (item['images'] as List).isNotEmpty)
                  ? (item['images'] as List).first.toString()
                  : '';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showProduct(item),
                  child: Row(children: [
                    if (image.startsWith('https://'))
                      SizedBox(
                          width: 100,
                          height: 110,
                          child: Image.network(image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.inventory_2_outlined)))
                    else
                      Container(
                          width: 100,
                          height: 110,
                          color: const Color(0xFFF0F2F8),
                          child:
                              const Icon(Icons.inventory_2_outlined, size: 34)),
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item['name']?.toString() ?? 'Product',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(item['description']?.toString() ?? '',
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 6),
                            Text('KSh ${item['price'] ?? '—'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF4F46E5))),
                            const SizedBox(height: 5),
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      (cart[id] ?? 0) > 0
                                          ? 'In cart: ${cart[id]}'
                                          : 'Tap to view details',
                                      style: const TextStyle(fontSize: 11))),
                              IconButton(
                                  onPressed: () => addProduct(item),
                                  icon: const Icon(Icons.add_circle_outline),
                                  tooltip: 'Add to cart'),
                            ]),
                          ]),
                    )),
                  ]),
                ),
              );
            }),
            if (cart.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'Your cart · ${cart.values.fold<int>(0, (sum, value) => sum + value)} item(s)',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        ...cart.entries.map((entry) {
                          final item = products.whereType<Map>().firstWhere(
                              (p) => p['_id']?.toString() == entry.key,
                              orElse: () => <String, dynamic>{});
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(item['name']?.toString() ?? 'Product'),
                            subtitle: Text(
                                '${entry.value} × KSh ${item['price'] ?? ''}'),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  onPressed: () => setState(() {
                                        if (entry.value <= 1) {
                                          cart.remove(entry.key);
                                        } else {
                                          cart[entry.key] = entry.value - 1;
                                        }
                                      }),
                                  icon:
                                      const Icon(Icons.remove_circle_outline)),
                              IconButton(
                                  onPressed: () {
                                    final product = products
                                        .whereType<Map>()
                                        .firstWhere(
                                            (p) =>
                                                p['_id']?.toString() ==
                                                entry.key,
                                            orElse: () => <String, dynamic>{});
                                    if (product.isNotEmpty) {
                                      addProduct(
                                          Map<String, dynamic>.from(product));
                                    }
                                  },
                                  icon: const Icon(Icons.add_circle_outline)),
                            ]),
                          );
                        }),
                        const Divider(),
                        Row(children: [
                          const Expanded(
                              child: Text('Total',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w800))),
                          Text('KSh ${total.toStringAsFixed(0)}',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w900)),
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
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: checkingOut ? null : checkout,
                              icon: checkingOut
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.lock_outline),
                              label: Text(checkingOut
                                  ? 'Starting secure checkout…'
                                  : 'Checkout with M-Pesa'),
                            )),
                      ]),
                ),
              ),
            if (notice != null)
              Card(
                  color: const Color(0xFFE9F8F2),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(notice!,
                              style: const TextStyle(color: Color(0xFF155E48))),
                          if (paymentId != null) ...[
                            const SizedBox(height: 8),
                            SelectableText('Payment reference: $paymentId'),
                            Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                    onPressed: refreshPayment,
                                    icon: const Icon(Icons.refresh),
                                    label:
                                        const Text('Refresh payment status'))),
                          ],
                        ]),
                  )),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
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
  List<dynamic> organizations = [],
      catalog = [],
      customers = [],
      documents = [],
      tasks = [];
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
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
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
        catalog = [];
        customers = [];
        documents = [];
        tasks = [];
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
      if (applied > 0) {
        await loadWorkspaceData(syncPending: false);
        return;
      }
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
          TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Business name')),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: industry,
            builder: (_, value, __) => DropdownButtonFormField<String>(
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Industry'),
              items: const [
                DropdownMenuItem(
                    value: 'retail', child: Text('Retail / wholesale')),
                DropdownMenuItem(
                    value: 'consulting', child: Text('Consultants / agencies')),
                DropdownMenuItem(
                    value: 'tourism', child: Text('Tourism / hospitality')),
                DropdownMenuItem(
                    value: 'logistics', child: Text('Transport / logistics')),
                DropdownMenuItem(
                    value: 'construction',
                    child: Text('Construction / trades')),
                DropdownMenuItem(
                    value: 'salon', child: Text('Salon / personal services')),
                DropdownMenuItem(
                    value: 'education', child: Text('Schools / training')),
                DropdownMenuItem(
                    value: 'agriculture', child: Text('Agriculture / produce')),
                DropdownMenuItem(
                    value: 'real_estate',
                    child: Text('Real estate / property')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (next) {
                if (next != null) industry.value = next;
              },
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    try {
      await app.api.call('POST', '/api/business/organizations',
          {'name': name.text.trim(), 'industry': industry.value});
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
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
    final title = kind == 'catalog'
        ? 'Add product or service'
        : kind == 'customer'
            ? 'Add customer'
            : kind == 'document'
                ? 'Create quotation'
                : 'Create follow-up task';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: kind == 'catalog'
                      ? 'Product / service name'
                      : kind == 'customer'
                          ? 'Customer name'
                          : kind == 'document'
                              ? 'Quotation title / item'
                              : 'Task title')),
          if (kind == 'catalog') ...[
            TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: 'Description')),
            TextField(
                controller: amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Price')),
            TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Stock quantity')),
          ] else if (kind == 'customer') ...[
            TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: 'Email or phone')),
          ] else if (kind == 'document') ...[
            ValueListenableBuilder<String>(
                valueListenable: docType,
                builder: (_, value, __) => DropdownButtonFormField<String>(
                    initialValue: value,
                    decoration:
                        const InputDecoration(labelText: 'Document type'),
                    items: const [
                      DropdownMenuItem(
                          value: 'quote', child: Text('Quotation')),
                      DropdownMenuItem(
                          value: 'invoice', child: Text('Invoice')),
                      DropdownMenuItem(
                          value: 'order', child: Text('Sales order'))
                    ],
                    onChanged: (next) {
                      if (next != null) docType.value = next;
                    })),
            TextField(
                controller: amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Unit price')),
            TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quantity')),
          ] else ...[
            TextField(
                controller: detail,
                decoration:
                    const InputDecoration(labelText: 'Notes / description')),
          ],
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(id)}';
      if (kind == 'catalog') {
        final price = double.tryParse(amount.text) ?? -1;
        if (price < 0) {
          throw const FormatException('Enter a valid non-negative price.');
        }
        await app.api.call('POST', '$base/catalog', {
          'name': name.text.trim(),
          'description': detail.text.trim(),
          'price': price,
          'stock': int.tryParse(quantity.text) ?? 0
        });
      } else if (kind == 'customer') {
        final contact = detail.text.trim();
        await app.api.call('POST', '$base/customers', {
          'name': name.text.trim(),
          if (contact.contains('@')) 'email': contact else 'phone': contact
        });
      } else if (kind == 'document') {
        final price = double.tryParse(amount.text) ?? -1;
        final count = int.tryParse(quantity.text) ?? 0;
        if (price < 0 || count < 1) {
          throw const FormatException('Enter a valid price and quantity.');
        }
        await app.api.call('POST', '$base/documents', {
          'type': docType.value,
          'items': [
            {'name': name.text.trim(), 'quantity': count, 'unitPrice': price}
          ]
        });
      } else {
        await app.api.call('POST', '$base/tasks', {
          'title': name.text.trim(),
          'description': detail.text.trim(),
          'type': 'follow_up'
        });
      }
      await loadWorkspaceData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Business record saved.')));
      }
    } catch (e) {
      if ((e is http.ClientException || e is TimeoutException) &&
          kind != 'document') {
        final entityType = kind == 'catalog'
            ? 'catalog'
            : kind == 'customer'
                ? 'customer'
                : 'task';
        final changes = kind == 'catalog'
            ? {
                'name': name.text.trim(),
                'description': detail.text.trim(),
                'price': double.tryParse(amount.text) ?? 0,
                'stock': int.tryParse(quantity.text) ?? 0
              }
            : kind == 'customer'
                ? {
                    'name': name.text.trim(),
                    if (detail.text.trim().contains('@'))
                      'email': detail.text.trim()
                    else
                      'phone': detail.text.trim()
                  }
                : {
                    'title': name.text.trim(),
                    'description': detail.text.trim(),
                    'type': 'follow_up'
                  };
        await _enqueueOfflineCreate(id, entityType, changes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Saved to the device queue. It will sync when connectivity returns.')));
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _offlineQueueKey(String id) => 'chatify_business_offline_$id';
  String _offlineIssuesKey(String id) => 'chatify_business_sync_issues_$id';

  // Persist only offline record creates; each mutation ID makes retry safe if the response is lost.
  Future<void> _enqueueOfflineCreate(
      String id, String entityType, Map<String, dynamic> changes) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    queue.add(jsonEncode({
      'mutationId':
          'mobile:$entityType:${DateTime.now().microsecondsSinceEpoch}',
      'operation': 'create',
      'entityType': entityType,
      'changes': changes
    }));
    await prefs.setStringList(key, queue);
    if (mounted) setState(() => pendingOfflineCount = queue.length);
  }

  Future<int> _flushOfflineQueue(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    if (queue.isEmpty) {
      if (mounted) setState(() => pendingOfflineCount = 0);
      return 0;
    }
    try {
      final mutations = queue
          .map((entry) => Map<String, dynamic>.from(jsonDecode(entry) as Map))
          .toList();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/sync',
          {'mutations': mutations});
      final results = List<dynamic>.from(response['results'] ?? []);
      final byId = <String, Map<String, dynamic>>{
        for (final result in results.whereType<Map>())
          result['mutationId'].toString(): Map<String, dynamic>.from(result)
      };
      final remaining = <String>[];
      final issues = prefs.getStringList(_offlineIssuesKey(id)) ?? <String>[];
      var applied = 0;
      for (final entry in queue) {
        final mutation = Map<String, dynamic>.from(jsonDecode(entry) as Map);
        final result = byId[mutation['mutationId'].toString()];
        if (result == null) {
          remaining.add(entry);
        } else if (result['status'] == 'applied') {
          applied++;
        } else {
          issues.add(jsonEncode({'mutation': mutation, 'result': result}));
        }
      }
      await prefs.setStringList(key, remaining);
      await prefs.setStringList(
          _offlineIssuesKey(id), issues.take(100).toList());
      if (mounted) {
        setState(() {
          pendingOfflineCount = remaining.length;
          syncConflicts = issues.take(100).toList();
        });
      }
      if (issues.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Some offline changes need review in Business Tools.')));
      }
      return applied;
    } catch (_) {
      if (mounted) setState(() => pendingOfflineCount = queue.length);
      return 0;
    }
  }

  // Publish or hide the customer-facing store without deleting the catalogue.
  // The server applies this flag to public discovery, storefront, enquiry and checkout routes.
  Future<void> _toggleStorefrontPublished() async {
    final id = organization?['_id']?.toString();
    if (id == null) return;
    final currentSettings = organization?['settings'] is Map
        ? Map<String, dynamic>.from(organization!['settings'] as Map)
        : <String, dynamic>{};
    final currentlyPublished = currentSettings['storefrontPublished'] != false;
    final next = !currentlyPublished;
    setState(() => saving = true);
    try {
      await app.api.call(
          'PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}', {
        'settings': {'storefrontPublished': next},
      });
      await loadOrganizations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(next
              ? 'Storefront published. Customers can now discover your business.'
              : 'Storefront hidden from public discovery. Your business records are unchanged.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
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
        final storefrontResponse = await app.api
            .call('GET', '/api/storefront/${Uri.encodeComponent(slug)}');
        final sellerDefault =
            storefrontResponse['storefront']?['sellerMpesaPhone']?.toString() ??
                '';
        if (sellerDefault.isNotEmpty) registeredPhone = sellerDefault;
      } catch (_) {
        // Keep the signed-in user's registered number as a useful offline/fallback default.
      }
    }
    // The storefront lookup above may yield after this screen is disposed; do not open a dialog using a stale context.
    if (!mounted) return;
    final currentSettings = organization?['settings'] is Map
        ? Map<String, dynamic>.from(organization!['settings'] as Map)
        : <String, dynamic>{};
    final phone = TextEditingController(
      text:
          currentSettings['mpesaRecipientPhone']?.toString().isNotEmpty == true
              ? currentSettings['mpesaRecipientPhone'].toString()
              : registeredPhone,
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Seller M-Pesa number'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Registered account number: ${registeredPhone.isEmpty ? 'Not set' : registeredPhone}'),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Customer payment number',
              hintText: '0712345678',
              helperText:
                  'Starts with your registered number. Change it if you want customers to pay using another Kenyan M-Pesa number. Leave blank to use your registered account number.',
              prefixIcon: Icon(Icons.phone_android),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save number')),
        ],
      ),
    );
    if (accepted != true) return;
    final id = organization?['_id']?.toString();
    if (id == null) return;
    try {
      await app.api.call(
          'PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}', {
        'settings': {'mpesaRecipientPhone': phone.text.trim()},
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Seller M-Pesa number saved.')));
      }
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _configureTaxProfile() async {
    final country = TextEditingController(
        text: organization?['country']?.toString() ?? 'KE');
    final currency = TextEditingController(
        text: organization?['currency']?.toString() ?? 'KES');
    final rate = TextEditingController(text: '0');
    String mode = 'exclusive';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Tax and currency profile'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: country,
                        maxLength: 2,
                        decoration: const InputDecoration(
                            labelText: 'Country code (e.g. KE)')),
                    TextField(
                        controller: currency,
                        maxLength: 3,
                        decoration: const InputDecoration(
                            labelText: 'Currency (e.g. KES)')),
                    TextField(
                        controller: rate,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Tax rate (%)')),
                    DropdownButtonFormField<String>(
                        initialValue: mode,
                        decoration:
                            const InputDecoration(labelText: 'Tax treatment'),
                        items: const [
                          DropdownMenuItem(
                              value: 'exclusive',
                              child: Text('Tax added on top')),
                          DropdownMenuItem(
                              value: 'inclusive', child: Text('Tax included')),
                          DropdownMenuItem(value: 'none', child: Text('No tax'))
                        ],
                        onChanged: (value) {
                          if (value != null) setDialogState(() => mode = value);
                        }),
                    const Text(
                        'Confirm local rates with your accountant or tax authority.',
                        style: TextStyle(fontSize: 12)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Save'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'PATCH',
          '/api/business/organizations/${Uri.encodeComponent(id)}/tax-profile',
          {
            'country': country.text.trim().toUpperCase(),
            'currency': currency.text.trim().toUpperCase(),
            'rate': double.tryParse(rate.text) ?? -1,
            'mode': mode
          });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Tax profile saved.')));
      }
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _translateBusinessText() async {
    final source = TextEditingController();
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Translate business text'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: source,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                            labelText: 'Text to translate')),
                    TextField(
                        controller: target,
                        decoration: const InputDecoration(
                            labelText: 'Target language')),
                    CheckboxListTile(
                        value: consent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'I consent to sending this text to the configured AI provider'),
                        onChanged: (value) =>
                            setDialogState(() => consent = value ?? false)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: consent
                            ? () => Navigator.pop(dialogContext, true)
                            : null,
                        child: const Text('Translate'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call('POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/translate', {
        'text': source.text,
        'targetLanguage': target.text.trim(),
        'consent': true
      });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('Translation'),
                  content: SelectableText(response['translated']?.toString() ??
                      'No translation returned.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Close'))
                  ]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _translateVoice() async {
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Voice message translation'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: target,
                        decoration: const InputDecoration(
                            labelText: 'Translate speech into')),
                    CheckboxListTile(
                        value: consent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'I consent to sending this audio to the configured AI provider'),
                        onChanged: (value) =>
                            setDialogState(() => consent = value ?? false)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: consent
                            ? () => Navigator.pop(dialogContext, true)
                            : null,
                        child: const Text('Choose audio'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final selected = await FilePicker.platform.pickFiles(
          type: FileType.audio, withData: true, allowMultiple: false);
      if (selected == null || selected.files.isEmpty) return;
      final file = selected.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty || bytes.length > 11 * 1024 * 1024) {
        throw const FormatException('Choose an audio file smaller than 11 MB.');
      }
      final extension = (file.extension ?? '').toLowerCase();
      final mime = switch (extension) {
        'mp3' || 'mpeg' => 'audio/mpeg',
        'm4a' || 'mp4' => 'audio/mp4',
        'wav' => 'audio/wav',
        'ogg' => 'audio/ogg',
        'webm' => 'audio/webm',
        _ => throw const FormatException(
            'Supported audio formats: MP3, M4A, WAV, OGG and WebM.'),
      };
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/voice-translate',
          {
            'audioBase64': base64Encode(bytes),
            'mimeType': mime,
            'targetLanguage': target.text.trim(),
            'consent': true
          });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Voice translation'),
                content: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Transcription',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SelectableText(
                          response['transcription']?.toString() ?? ''),
                      const SizedBox(height: 12),
                      const Text('Translation',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SelectableText(response['translated']?.toString() ?? ''),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Close'))
                ],
              ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _memorySuggestions() async {
    final source = TextEditingController();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
                title: const Text('Business Memory suggestions'),
                content: TextField(
                    controller: source,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                        labelText: 'Paste a conversation or business note')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Find suggestions'))
                ]));
    if (accepted != true || source.text.trim().isEmpty) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/memory-candidates',
          {'text': source.text});
      final candidates = List<dynamic>.from(response['candidates'] ?? []);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('Review suggestions'),
                  content: SizedBox(
                      width: 420,
                      child: candidates.isEmpty
                          ? const Text('No clear candidates found.')
                          : ListView(
                              shrinkWrap: true,
                              children: candidates
                                  .whereType<Map>()
                                  .map((item) => ListTile(
                                      title: Text(item['title']?.toString() ??
                                          'Suggestion'),
                                      subtitle: Text(
                                          '${item['type']}: ${item['description']}')))
                                  .toList())),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Close'))
                  ]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _sendCustomerMessage() async {
    final eligible = customers.whereType<Map>().toList();
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add a customer before sending a message.')));
      return;
    }
    String? customerId = eligible.first['_id']?.toString();
    String channel = 'whatsapp';
    bool confirmedOptIn = false;
    final message = TextEditingController();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Message a customer'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<String>(
                        initialValue: customerId,
                        decoration:
                            const InputDecoration(labelText: 'Customer'),
                        items: eligible
                            .map((item) => DropdownMenuItem<String>(
                                value: item['_id']?.toString(),
                                child: Text(
                                    item['name']?.toString() ?? 'Customer',
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (value) =>
                            setDialogState(() => customerId = value)),
                    DropdownButtonFormField<String>(
                        initialValue: channel,
                        decoration: const InputDecoration(labelText: 'Channel'),
                        items: const [
                          DropdownMenuItem(
                              value: 'whatsapp', child: Text('WhatsApp')),
                          DropdownMenuItem(value: 'sms', child: Text('SMS'))
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => channel = value);
                          }
                        }),
                    TextField(
                        controller: message,
                        minLines: 2,
                        maxLines: 5,
                        decoration:
                            const InputDecoration(labelText: 'Message')),
                    CheckboxListTile(
                        value: confirmedOptIn,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Customer has explicitly opted in'),
                        onChanged: (value) => setDialogState(
                            () => confirmedOptIn = value ?? false)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed:
                            confirmedOptIn && message.text.trim().isNotEmpty
                                ? () => Navigator.pop(dialogContext, true)
                                : null,
                        child: const Text('Send'))
                  ],
                )));
    if (accepted != true || customerId == null) return;
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      await app.api.call(
          'PATCH',
          '$base/customers/${Uri.encodeComponent(customerId!)}/messaging-consent',
          {'consent': true});
      final response = await app.api.call('POST', '$base/communications/send', {
        'customerId': customerId,
        'channel': channel,
        'message': message.text.trim()
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Message submitted.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _createScheduledWorkflow() async {
    final name = TextEditingController(text: 'Daily follow-up reminder');
    final interval = TextEditingController(text: '60');
    final actionText =
        TextEditingController(text: 'Review open customer follow-ups');
    String action = 'create_task';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Scheduled workflow'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: name,
                        decoration:
                            const InputDecoration(labelText: 'Workflow name')),
                    TextField(
                        controller: interval,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Repeat every minutes (5–10080)')),
                    DropdownButtonFormField<String>(
                        initialValue: action,
                        decoration: const InputDecoration(labelText: 'Action'),
                        items: const [
                          DropdownMenuItem(
                              value: 'create_task',
                              child: Text('Create follow-up task')),
                          DropdownMenuItem(
                              value: 'notify_team',
                              child: Text('Notify team in Chatify'))
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => action = value);
                          }
                        }),
                    TextField(
                        controller: actionText,
                        decoration: InputDecoration(
                            labelText: action == 'create_task'
                                ? 'Task title'
                                : 'Notification')),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Create and enable'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      final created = await app.api.call('POST', '$base/workflows', {
        'name': name.text.trim(),
        'trigger': 'schedule',
        'scheduleEveryMinutes': int.tryParse(interval.text) ?? 60,
        'actions': [
          {
            'actionType': action,
            'config': action == 'create_task'
                ? {'title': actionText.text.trim()}
                : {'message': actionText.text.trim()}
          }
        ]
      });
      final workflowId = (created['workflow'] as Map?)?['_id']?.toString();
      if (workflowId == null) {
        throw const FormatException(
            'Workflow was created but its ID was missing.');
      }
      await app.api.call(
          'POST', '$base/workflows/${Uri.encodeComponent(workflowId)}/test', {
        'sample': {'source': 'mobile setup'}
      });
      await app.api.call(
          'PATCH',
          '$base/workflows/${Uri.encodeComponent(workflowId)}',
          {'enabled': true});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Workflow enabled. Keep the backend worker running.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _invoiceIntegration(String documentId, String action) async {
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(documentId)}';
      Map<String, dynamic> response;
      if (action == 'stripe' || action == 'paypal') {
        final providerRoute =
            action == 'stripe' ? 'stripe-checkout' : 'paypal-checkout';
        response = await app.api.call('POST', '$base/$providerRoute', {});
        final checkoutUrl = response['payment'] is Map
            ? (response['payment'] as Map)['checkoutUrl']?.toString()
            : null;
        if (checkoutUrl == null ||
            !await launchUrl(Uri.parse(checkoutUrl),
                mode: LaunchMode.externalApplication)) {
          if (mounted && checkoutUrl != null) {
            await showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                        title: const Text('Hosted checkout'),
                        content: SelectableText(checkoutUrl),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'))
                        ]));
          }
        }
      } else if (action == 'mpesa') {
        final preview = await app.api.call('GET', '$base/mpesa-fee-preview');
        final baseAmount = (preview['baseAmount'] as num?)?.toInt() ?? 0;
        final platformFee = (preview['platformFee'] as num?)?.toInt() ?? 0;
        final totalAmount = (preview['totalAmount'] as num?)?.toInt() ?? baseAmount + platformFee;
        final phone = TextEditingController();
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                    title: const Text('Review invoice M-Pesa total'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Invoice balance: KSh $baseAmount\nChatify platform fee (0.5%, rounded up to whole KSh): KSh $platformFee\nBuyer total: KSh $totalAmount'),
                      const SizedBox(height: 8),
                      const Text('The platform fee remains pending settlement and is not automatically transferred to Chatify. Disclose this total to the customer before sending the prompt.', style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer M-Pesa phone')),
                    ]),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Confirm and send STK'))
                    ]));
        if (accepted != true) { phone.dispose(); return; }
        response = await app.api
            .call('POST', '$base/mpesa-stk', {'phone': phone.text.trim()});
        phone.dispose();
      } else {
        response = await app.api.call('POST', '$base/etims-submit', {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Request submitted.')));
      }
      await loadWorkspaceData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showPaymentMatching(String documentId) async {
    try {
      final orgId = Uri.encodeComponent(organization!['_id'].toString());
      final path =
          '/api/business/organizations/$orgId/documents/${Uri.encodeComponent(documentId)}/payment-matching';
      final result = await app.api.call('GET', path);
      final matches = List<dynamic>.from(result['matches'] ?? []);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Payment matching · ${result['number'] ?? 'Invoice'}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      'Confirmed paid: ${result['currency'] ?? 'KES'} ${result['confirmedPaidAmount'] ?? 0}'),
                  Text(
                      'Outstanding: ${result['currency'] ?? 'KES'} ${result['outstandingAmount'] ?? 0}'),
                  const SizedBox(height: 8),
                  const Text(
                      'Confidence is a triage hint only. Unverified manual references are not proof of payment.'),
                  const Divider(),
                  if (matches.isEmpty)
                    const Text('No payment records attached to this document.'),
                  for (final match in matches.whereType<Map>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(match['verified'] == true
                          ? Icons.verified_outlined
                          : Icons.warning_amber_outlined),
                      title: Text(
                          '${match['status'] ?? 'unmatched'} · ${result['currency'] ?? 'KES'} ${match['amount'] ?? 0}'),
                      subtitle: Text(
                          'Confidence: ${match['confidence'] ?? 0}% · Reference: ${match['reference'] ?? 'none'}\n${match['notice'] ?? ''}'),
                    ),
                ])),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'))
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _shareBusinessDocument(String documentId) async {
    try {
      final orgId = Uri.encodeComponent(organization!['_id'].toString());
      final result = await app.api.call(
          'POST', '/api/business/organizations/$orgId/enterprise/shares', {
        'entityType': 'document',
        'entityId': documentId,
        'expiresInHours': 72,
      });
      final path = result['path']?.toString() ?? '';
      if (path.isEmpty || !mounted) return;
      final link = Uri.parse(app.api.base).resolve(path).toString();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Customer document link'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'The customer can view this document without seeing internal notes. The link expires in 72 hours.'),
                const SizedBox(height: 8),
                SelectableText(link),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Customer document link copied.')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showDocumentActions(Map item) async {
    final type = item['type']?.toString() ?? '';
    final status = item['status']?.toString() ?? '';
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Wrap(children: [
              ListTile(
                  title: Text(item['number']?.toString() ?? 'Sales document'),
                  subtitle: Text('Status: $status')),
              if (!['draft', 'rejected', 'cancelled'].contains(status))
                ListTile(
                    leading: const Icon(Icons.link),
                    title:
                        const Text('Share customer link (expires in 72 hours)'),
                    onTap: () => Navigator.pop(context, 'share')),
              if (type == 'invoice' && status != 'draft')
                ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('Review payment matching'),
                    onTap: () => Navigator.pop(context, 'matching')),
              if (status == 'draft')
                ListTile(
                    leading: const Icon(Icons.send),
                    title: const Text('Issue / send document'),
                    onTap: () => Navigator.pop(context, 'issue')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.credit_card),
                    title: const Text('Pay online (Stripe)'),
                    onTap: () => Navigator.pop(context, 'stripe')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('Pay with PayPal'),
                    onTap: () => Navigator.pop(context, 'paypal')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.payments),
                    title: const Text('Request M-Pesa STK payment'),
                    onTap: () => Navigator.pop(context, 'mpesa')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['cancelled', 'rejected'].contains(status))
                ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title:
                        const Text('Submit through configured eTIMS gateway'),
                    onTap: () => Navigator.pop(context, 'etims')),
            ])));
    if (action == null) return;
    final id = item['_id']?.toString();
    if (id == null) return;
    if (action == 'share') {
      await _shareBusinessDocument(id);
      return;
    }
    if (action == 'matching') {
      await _showPaymentMatching(id);
      return;
    }
    try {
      if (action == 'issue') {
        final path =
            '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(id)}/status';
        await app.api.call('PATCH', path, {'status': 'sent'});
        await loadWorkspaceData();
      } else {
        await _invoiceIntegration(id, action);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Widget toolsPanel() => ListView(padding: const EdgeInsets.all(12), children: [
        // Keep the enterprise feature suite visible from the existing Business Tools panel.
        Card(
            child: ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: const Text('Enterprise workspace'),
          subtitle: const Text(
              'Handbook, approvals, customer promises, disputes, projects, incidents and global search'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => BusinessEnterprisePage(
              organizationId: organization!['_id'].toString(),
              organizationName: organization!['name']?.toString() ?? 'Business',
            ),
          )),
        )),
        Card(
            child: ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Tax and currency profile'),
                subtitle:
                    const Text('Configure jurisdiction and tax treatment'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _configureTaxProfile)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.translate),
                title: const Text('Translate business text'),
                subtitle: const Text('Consent-gated AI translation'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _translateBusinessText)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('Translate voice message'),
                subtitle: const Text(
                    'Transcribe and translate an audio file with consent'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _translateVoice)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.psychology_alt),
                title: const Text('Business Memory suggestions'),
                subtitle: const Text(
                    'Find possible tasks, dates and payment details'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _memorySuggestions)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: const Text('Message a customer'),
                subtitle: const Text('WhatsApp / SMS; opt-in required'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _sendCustomerMessage)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Scheduled workflow'),
                subtitle:
                    const Text('Create, test and enable an allowed action'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _createScheduledWorkflow)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.sync),
                title: Text('Sync offline records ($pendingOfflineCount)'),
                subtitle: Text(syncConflicts.isEmpty
                    ? 'Queued creates sync when connected'
                    : '${syncConflicts.length} changes need review'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final id = organization!['_id'].toString();
                  final applied = await _flushOfflineQueue(id);
                  if (applied > 0) await loadWorkspaceData(syncPending: false);
                  if (syncConflicts.isNotEmpty && mounted) {
                    await showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title: const Text('Sync conflicts'),
                                content: SizedBox(
                                    width: 420,
                                    child: ListView(
                                        shrinkWrap: true,
                                        children: syncConflicts.map((entry) {
                                          final item = jsonDecode(entry) as Map;
                                          final result =
                                              item['result'] as Map? ?? {};
                                          return ListTile(
                                              title: Text(result['status']
                                                      ?.toString() ??
                                                  'Needs review'),
                                              subtitle: Text(result['error']
                                                      ?.toString() ??
                                                  result['reason']
                                                      ?.toString() ??
                                                  'Server record changed; compare versions before retrying.'));
                                        }).toList())),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'))
                                ]));
                  }
                })),
      ]);

  Widget metric(String label, dynamic value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(icon, size: 24),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(value?.toString() ?? '0',
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ])),
          ]),
        ),
      );

  Widget recordList(List<dynamic> records, String kind, IconData icon) {
    if (records.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No $kind yet. Use Add to create your first record.',
                  textAlign: TextAlign.center)));
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: records.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final item = records[index];
        if (item is! Map) return const SizedBox.shrink();
        final title = item['name']?.toString() ??
            item['title']?.toString() ??
            item['number']?.toString() ??
            kind;
        final subtitle = item['description']?.toString() ??
            item['company']?.toString() ??
            item['status']?.toString() ??
            '';
        final amount = item['price'] ?? item['total'];
        return ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: amount == null
              ? null
              : Text('${item['currency'] ?? 'KES'} $amount'),
          onTap: kind == 'sales documents'
              ? () => _showDocumentActions(Map<String, dynamic>.from(item))
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null && organizations.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.business_outlined, size: 48),
                const SizedBox(height: 12),
                Text(error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: loadOrganizations, child: const Text('Retry')),
              ])));
    }
    if (organization == null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.storefront_outlined, size: 56),
                const SizedBox(height: 12),
                Text('Turn conversations into business',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text(
                    'Create a workspace to manage customers, products, quotations and follow-ups alongside your conversations.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                    onPressed: createOrganization,
                    icon: const Icon(Icons.add_business),
                    label: const Text('Create business workspace')),
              ])));
    }
    final metrics = dashboard;
    return DefaultTabController(
      length: 5,
      child: Column(children: [
        // Keep workspace actions visible and labelled; icon-only actions were easy to miss,
        // especially on touch screens and when this dashboard was used in a browser.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonHideUnderline(
                child: DropdownButton<String>(
              isExpanded: true,
              value: organization!['_id']?.toString(),
              items: organizations
                  .whereType<Map>()
                  .map((item) => DropdownMenuItem<String>(
                      value: item['_id'].toString(),
                      child: Text(item['name']?.toString() ?? 'Business',
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (id) async {
                if (id == null) return;
                setState(() {
                  organization = organizations
                      .whereType<Map>()
                      .firstWhere((item) => item['_id'].toString() == id)
                      .cast<String, dynamic>();
                  loading = true;
                });
                await loadWorkspaceData();
                if (mounted) setState(() => loading = false);
              },
            )),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    final slug = organization?['slug']?.toString() ?? '';
                    if (slug.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'This workspace has no storefront slug yet.')));
                      return;
                    }
                    Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => StorefrontPage(slug: slug)));
                  },
                  icon: const Icon(Icons.storefront_outlined),
                  label: const Text('View storefront'),
                ),
                OutlinedButton.icon(
                  onPressed: saving ? null : _toggleStorefrontPublished,
                  icon: Icon((organization?['settings'] is Map &&
                          (organization!['settings']
                                  as Map)['storefrontPublished'] ==
                              false)
                      ? Icons.publish_outlined
                      : Icons.visibility_off_outlined),
                  label: Text((organization?['settings'] is Map &&
                          (organization!['settings']
                                  as Map)['storefrontPublished'] ==
                              false)
                      ? 'Publish storefront'
                      : 'Hide storefront'),
                ),
                OutlinedButton.icon(
                  onPressed: _configureMpesaNumbers,
                  icon: const Icon(Icons.phone_android),
                  label: const Text('M-Pesa settings'),
                ),
                FilledButton.icon(
                  onPressed: () {
                    final id = organization?['_id']?.toString();
                    if (id == null) return;
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => MerchantPosPage(
                        organizationId: id,
                        organizationName: organization?['name']?.toString() ?? 'Business',
                      ),
                    ));
                  },
                  icon: const Icon(Icons.point_of_sale_outlined),
                  label: const Text('In-person POS payments'),
                ),
                OutlinedButton.icon(
                  onPressed: loadOrganizations,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                FilledButton.tonalIcon(
                  onPressed: createOrganization,
                  icon: const Icon(Icons.add_business),
                  label: const Text('Add workspace'),
                ),
              ],
            ),
          ]),
        ),
        SizedBox(
            height: 118,
            child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  SizedBox(
                      width: 170,
                      child: metric('Customers', metrics['customers'],
                          Icons.people_outline)),
                  SizedBox(
                      width: 170,
                      child: metric(
                          'Products / services',
                          metrics['activeCatalogItems'],
                          Icons.inventory_2_outlined)),
                  SizedBox(
                      width: 170,
                      child: metric(
                          'Open tasks', metrics['openTasks'], Icons.task_alt)),
                  SizedBox(
                      width: 170,
                      child: metric('Open cases', metrics['openCases'],
                          Icons.support_agent_outlined)),
                ])),
        const TabBar(isScrollable: true, tabs: [
          Tab(text: 'Catalogue'),
          Tab(text: 'Customers'),
          Tab(text: 'Sales'),
          Tab(text: 'Tasks'),
          Tab(text: 'Tools'),
        ]),
        Expanded(
            child: TabBarView(children: [
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('catalog'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add product / service'))),
            Expanded(
                child: recordList(catalog, 'products or services',
                    Icons.inventory_2_outlined))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('customer'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add customer'))),
            Expanded(
                child: recordList(customers, 'customers', Icons.person_outline))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('document'),
                    icon: const Icon(Icons.add),
                    label: const Text('Create quotation'))),
            Expanded(
                child: recordList(
                    documents, 'sales documents', Icons.receipt_long_outlined))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('task'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add task / follow-up'))),
            Expanded(child: recordList(tasks, 'tasks', Icons.task_alt))
          ]),
          toolsPanel(),
        ])),
        if (saving) const LinearProgressIndicator(),
        if (error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
      ]),
    );
  }
}

// Merchant checkout for shops, supermarkets, malls, hotels and restaurants.
class MerchantPosPage extends StatefulWidget {
  const MerchantPosPage({super.key, required this.organizationId, required this.organizationName});
  final String organizationId, organizationName;
  @override
  State<MerchantPosPage> createState() => _MerchantPosPageState();
}
class _MerchantPosPageState extends State<MerchantPosPage> {
  AppState get app => context.read<AppState>();
  final till = TextEditingController(), paybill = TextEditingController(),
      amount = TextEditingController(),
      description = TextEditingController(), reference = TextEditingController(),
      darajaConsumerKey = TextEditingController(), darajaConsumerSecret = TextEditingController(),
      darajaPasskey = TextEditingController();
  String method = 'mpesa_till', darajaMode = 'production';
  bool loading = true, saving = false, darajaConfigured = false;
  Map<String, dynamic>? profile;
  List<dynamic> charges = [];
  String? error;
  String get base => '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/pos';
  @override
  void initState() { super.initState(); load(); }
  @override
  void dispose() { till.dispose(); paybill.dispose(); amount.dispose(); description.dispose(); reference.dispose(); darajaConsumerKey.dispose(); darajaConsumerSecret.dispose(); darajaPasskey.dispose(); super.dispose(); }

  Future<void> load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final r = await Future.wait([app.api.call('GET', '$base/payment-profile'), app.api.call('GET', '$base/charges')]);
      profile = r[0]['paymentProfile'] is Map ? Map<String,dynamic>.from(r[0]['paymentProfile']) : null;
      darajaConfigured = r[0]['darajaConfigured'] == true;
      charges = List<dynamic>.from(r[1]['charges'] ?? []);
      if (profile != null) {
        method = profile!['method']?.toString() ?? 'mpesa_till';
        till.text = profile!['tillNumber']?.toString() ?? '';
        paybill.text = profile!['paybillNumber']?.toString() ?? '';
      }
    } catch (e) { error = e.toString(); }
    finally { if (mounted) setState(() => loading = false); }
  }

  Future<void> saveProfile() async {
    setState(() => saving = true);
    try {
      final body = <String,dynamic>{'method': method};
      if (method == 'mpesa_till') { body['tillNumber'] = till.text.trim(); }
      else { body['paybillNumber'] = paybill.text.trim(); }
      final hasAnyCredential = darajaConsumerKey.text.trim().isNotEmpty || darajaConsumerSecret.text.trim().isNotEmpty || darajaPasskey.text.trim().isNotEmpty;
      if (hasAnyCredential) {
        if (darajaConsumerKey.text.trim().isEmpty || darajaConsumerSecret.text.trim().isEmpty || darajaPasskey.text.trim().isEmpty) {
          throw Exception('Enter the merchant consumer key, consumer secret and passkey together, or leave all three blank.');
        }
        body.addAll({'mode': darajaMode, 'shortcode': method == 'mpesa_till' ? till.text.trim() : paybill.text.trim(),
          'consumerKey': darajaConsumerKey.text.trim(), 'consumerSecret': darajaConsumerSecret.text.trim(), 'passkey': darajaPasskey.text.trim()});
      }
      final r = await app.api.call('PUT', '$base/payment-profile', body);
      profile = Map<String,dynamic>.from(r['paymentProfile'] ?? body);
      darajaConfigured = r['darajaConfigured'] == true;
      darajaConsumerKey.clear(); darajaConsumerSecret.clear(); darajaPasskey.clear();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Merchant payment instructions saved.')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
    finally { if (mounted) setState(() => saving = false); }
  }

  Future<void> createCharge() async {
    final n = int.tryParse(amount.text.trim());
    if (n == null || n < 1 || n > 150000 || description.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a description and whole-number amount from KSh 1 to KSh 150,000.')));
      return;
    }
    final fee = (n * 0.005).ceil();
    final total = n + fee;
    final accepted = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('Confirm POS checkout fee'),
      content: Text('Sale amount: KSh $n\nChatify platform fee (0.5%): KSh $fee\nBuyer total: KSh $total\n\nShow this breakdown to the buyer before they scan/pay. The fee is accrued as pending settlement; it is not automatically transferred to Chatify.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create payment QR')),
      ],
    ));
    if (accepted != true) return;
    setState(() => saving = true);
    try {
      final r = await app.api.call('POST', '$base/charges', {
        'amount': n, 'description': description.text.trim(),
        if (reference.text.trim().isNotEmpty) 'reference': reference.text.trim(),
      });
      amount.clear(); description.clear(); reference.clear();
      if (mounted) await showCharge(Map<String,dynamic>.from(r['charge'] ?? {}));
      await load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
    finally { if (mounted) setState(() => saving = false); }
  }

  Future<void> initiateStk(Map<String,dynamic> item, String phone) async {
    if (phone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the customer M-Pesa phone number first.')));
      return;
    }
    try {
      await app.api.call('POST', '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}/stk', {'phone': phone.trim()});
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('STK prompt sent. The sale remains pending until Safaricom confirms payment.')));
      }
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> reconcileCharge(Map<String,dynamic> item) async {
    final receipt = TextEditingController();
    bool verified = false;
    final accepted = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Verify M-Pesa receipt'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Sale reference: ${item['reference'] ?? ''} · KSh ${item['amount'] ?? ''}'),
          TextField(controller: receipt, textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'M-Pesa receipt number')),
          CheckboxListTile(value: verified, contentPadding: EdgeInsets.zero,
            title: const Text('I checked the receipt in the official merchant M-Pesa account or statement'),
            onChanged: (value) => setDialogState(() => verified = value ?? false)),
          const Text('This records a manual finance reconciliation; it does not verify the receipt with Safaricom.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: verified && receipt.text.trim().isNotEmpty ? () => Navigator.pop(d, true) : null, child: const Text('Record as verified')),
        ],
      ),
    ));
    if (accepted == true) {
      try {
        await app.api.call('POST', '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}/reconcile', {
          'receipt': receipt.text.trim().toUpperCase(), 'verified': verified,
        });
        await load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt recorded as manually reconciled.')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
    receipt.dispose();
  }

  Future<void> showCharge(Map<String,dynamic> item) async {
    if (item['qrPayload'] == null && item['paymentId'] != null) {
      try {
        final details = await app.api.call('GET', '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}');
        item = Map<String,dynamic>.from(details['charge'] ?? item);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load payment QR: $e')));
        return;
      }
    }
    if (!mounted) return;
    final payload = item['qrPayload']?.toString() ?? '';
    final dynamicQrImage = item['dynamicQrImage']?.toString() ?? '';
    final stkPhone = TextEditingController();
    final isSafaricomQr = item['qrProvider'] == 'safaricom_dynamic_qr' && dynamicQrImage.isNotEmpty;
    await showDialog<void>(context: context, builder: (d) => AlertDialog(
      title: const Text('Customer checkout'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (isSafaricomQr)
          Image.memory(base64Decode(dynamicQrImage), width: 220, height: 220, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text('Could not display the M-Pesa QR image. Refresh and try again.'))
        else if (payload.isNotEmpty)
          QrImageView(data: payload, version: QrVersions.auto, size: 220, backgroundColor: Colors.white),
        Text(widget.organizationName, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        Text('Buyer total: KSh ${item['totalAmount'] ?? item['amount'] ?? ''}', style: Theme.of(context).textTheme.headlineSmall),
        Text('Sale amount: KSh ${item['baseAmount'] ?? item['amount'] ?? ''}  +  Chatify fee: KSh ${item['platformFee'] ?? 0} (0.5%, rounded up to whole KSh)', textAlign: TextAlign.center),
        const Text('Platform fee is pending settlement; this payment is not automatically split or transferred to Chatify.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
        Text(item['description']?.toString() ?? ''),
        SelectableText('Reference: ${item['reference'] ?? ''}'),
        Text('Status: ${item['status'] ?? 'PENDING'}'),
        const SizedBox(height: 8),
        Text(isSafaricomQr
          ? 'Scan this Safaricom Dynamic QR with the M-Pesa app to pay the merchant. The sale remains pending until the provider callback confirms the matching transaction.'
          : 'Demo/instruction QR only. Customer scans with Chatify to view the merchant details, then pays in M-Pesa. This does not confirm payment.',
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
        if (!isSafaricomQr)
          TextButton.icon(onPressed: () async { await Clipboard.setData(ClipboardData(text: payload)); }, icon: const Icon(Icons.copy), label: const Text('Copy QR payload')),
        const Divider(height: 24),
        TextField(controller: stkPhone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer M-Pesa phone', hintText: '0712345678 or 254712345678')),
        const SizedBox(height: 6),
        Text(darajaConfigured ? 'STK uses this merchant\'s own authorized Daraja shortcode.' : 'Configure authorized merchant Daraja credentials to enable direct STK Push.', style: const TextStyle(fontSize: 12)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
        FilledButton.icon(onPressed: saving || !darajaConfigured ? null : () => initiateStk(item, stkPhone.text), icon: const Icon(Icons.phone_android), label: const Text('Send STK Push')),
      ],
    ));
    stkPhone.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(appBar: AppBar(title: const Text('In-person POS payments'), actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(onRefresh: load, child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(widget.organizationName, style: Theme.of(context).textTheme.headlineSmall),
        const Text('Create cashier checkout requests for retail purchases, restaurant bills, hotel stays and other sales.'),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Merchant payment destination', style: Theme.of(context).textTheme.titleLarge),
          DropdownButtonFormField<String>(initialValue: method, decoration: const InputDecoration(labelText: 'Method'), items: const [
            DropdownMenuItem(value: 'mpesa_till', child: Text('M-Pesa Buy Goods / Till')),
            DropdownMenuItem(value: 'mpesa_paybill', child: Text('M-Pesa Paybill')),
          ], onChanged: saving ? null : (v) { if (v != null) setState(() => method = v); }),
          if (method == 'mpesa_till') TextField(controller: till, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Merchant Till number')),
          if (method == 'mpesa_paybill') ...[
            TextField(controller: paybill, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Merchant Paybill number')),
          ],
          const SizedBox(height: 8),
          const SizedBox(height: 12),
          Text('Merchant Daraja authorization', style: Theme.of(context).textTheme.titleMedium),
          DropdownButtonFormField<String>(initialValue: darajaMode, decoration: const InputDecoration(labelText: 'Daraja environment'), items: const [
            DropdownMenuItem(value: 'sandbox', child: Text('Sandbox / testing')),
            DropdownMenuItem(value: 'production', child: Text('Production / live payments')),
          ], onChanged: saving ? null : (v) { if (v != null) setState(() => darajaMode = v); }),
          TextField(controller: darajaConsumerKey, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'Merchant Daraja consumer key (optional)')),
          TextField(controller: darajaConsumerSecret, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'Merchant Daraja consumer secret (optional)')),
          TextField(controller: darajaPasskey, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'Merchant STK passkey (optional)')),
          const SizedBox(height: 6),
          Text(darajaConfigured ? 'Authorized merchant credentials are stored encrypted. Leave secret fields blank to keep the existing credentials.' : 'Enter all three secrets from the merchant\'s authorized Daraja app. The shortcode must match the Till or Paybill above.', style: const TextStyle(fontSize: 12)),
          FilledButton.icon(onPressed: saving ? null : saveProfile, icon: const Icon(Icons.lock_outline), label: const Text('Save destination and secure credentials')),
        ]))),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Create checkout', style: Theme.of(context).textTheme.titleLarge),
          TextField(controller: description, decoration: const InputDecoration(labelText: 'Purchase / bill description', hintText: 'Groceries, dinner, room deposit…')),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (KES)', prefixText: 'KSh ')),
          TextField(controller: reference, decoration: const InputDecoration(labelText: 'Optional order / table / room reference')),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: saving || profile == null ? null : createCharge, icon: const Icon(Icons.qr_code_2), label: const Text('Create payment QR')),
          if (profile == null) const Text('Save your payment destination before creating a checkout.', style: TextStyle(fontSize: 12)),
        ]))),
        Text('Recent payment requests', style: Theme.of(context).textTheme.titleLarge),
        if (charges.isEmpty) const Text('No POS payment requests yet.'),
        ...charges.map((raw) {
          final item = Map<String,dynamic>.from(raw as Map);
          final st = (item['status']?.toString() ?? 'PENDING').toUpperCase();
          final source = item['confirmationSource']?.toString() ?? '';
          final receipt = item['providerReceipt']?.toString() ?? '';
          final subtitle = '${item['reference'] ?? ''} · $st\n${item['createdAt'] ?? ''}'
            '${receipt.isNotEmpty ? '\nReceipt: $receipt' : ''}'
            '${source == 'manual_merchant_reconciliation' ? '\nManually verified by merchant' : source == 'safaricom_c2b' ? '\nConfirmed by Safaricom C2B' : ''}';
          return Card(child: ListTile(
            leading: Icon(st == 'SUCCESS' ? Icons.check_circle : st == 'FAILED' ? Icons.error_outline : Icons.hourglass_top),
            title: Text('KSh ${item['amount'] ?? ''} · ${item['description'] ?? 'Sale'}'),
            subtitle: Text(subtitle),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Show payment QR', icon: const Icon(Icons.qr_code_2), onPressed: () => showCharge(item)),
              if (st == 'PENDING') IconButton(tooltip: 'Record receipt after official verification', icon: const Icon(Icons.fact_check_outlined), onPressed: () => reconcileCharge(item)),
            ]),
          ));
        }),
        const Text('Do not release goods or close a bill based on a QR scan or screenshot. Wait for independently verified payment confirmation.', style: TextStyle(fontSize: 12)),
      ])));
  }
}

// Customer scans the Chatify checkout QR and reads the payment destination.
class MerchantQrScannerPage extends StatefulWidget {
  const MerchantQrScannerPage({super.key});
  @override
  State<MerchantQrScannerPage> createState() => _MerchantQrScannerPageState();
}
class _MerchantQrScannerPageState extends State<MerchantQrScannerPage> {
  Map<String,dynamic>? charge;
  String? error;
  bool handled = false;
  void onDetect(BarcodeCapture capture) {
    if (handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final d = jsonDecode(raw);
        if (d is! Map || d['type'] != 'chatify_pos_payment' || d['currency'] != 'KES' || d['paymentId'] == null || d['reference'] == null || d['amount'] is! num || d['amount'] < 1 || d['amount'] > 150000) {
          throw const FormatException('Invalid Chatify merchant payment QR.');
        }
        handled = true; if (mounted) setState(() { charge = Map<String,dynamic>.from(d); error = null; }); return;
      } catch (_) {
        handled = true;
        if (mounted) setState(() => error = 'This may be a Safaricom Dynamic QR. Scan that QR with the M-Pesa app; Chatify reads its own checkout-instruction QR only.');
        return;
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = charge;
    final dest = c == null ? '' : c['method'] == 'mpesa_till' ? 'M-Pesa Till: ${c['tillNumber'] ?? ''}' : 'M-Pesa Paybill: ${c['paybillNumber'] ?? ''}\nAccount/reference: ${c['accountNumber'] ?? ''}';
    return Scaffold(appBar: AppBar(title: const Text('Pay a merchant')), body: ListView(padding: const EdgeInsets.all(16), children: [
      if (c == null) ...[
        const Text('Scan the cashier’s Chatify QR and verify the merchant and amount.'),
        SizedBox(height: 320, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: MobileScanner(onDetect: onDetect))),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        OutlinedButton.icon(onPressed: () => setState(() { handled = false; error = null; }), icon: const Icon(Icons.refresh), label: const Text('Scan again')),
      ] else Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.storefront, size: 48),
        Text(c['merchantName']?.toString() ?? 'Merchant', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        Text('KSh ${c['amount']}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
        Text(c['description']?.toString() ?? 'Purchase', textAlign: TextAlign.center),
        const Divider(height: 24), SelectableText(dest), SelectableText('Reference: ${c['reference']}'),
        const SizedBox(height: 12),
        const Text('Open M-Pesa and use Buy Goods or Paybill. Enter the exact merchant details and verify the amount before confirming. Scanning this QR does not transfer money or prove payment.', style: TextStyle(fontSize: 13)),
        FilledButton.icon(onPressed: () async { await Clipboard.setData(ClipboardData(text: dest)); }, icon: const Icon(Icons.copy), label: const Text('Copy payment details')),
        OutlinedButton.icon(onPressed: () => setState(() { charge = null; handled = false; error = null; }), icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan another payment')),
      ]))),
    ]));
  }
}

// A single, permission-aware screen exposes the enterprise APIs without duplicating business data.
// Every operation is scoped by the selected organization ID and re-authorized by the server.
class BusinessEnterprisePage extends StatefulWidget {
  const BusinessEnterprisePage(
      {super.key,
      required this.organizationId,
      required this.organizationName});
  final String organizationId;
  final String organizationName;

  @override
  State<BusinessEnterprisePage> createState() => _BusinessEnterprisePageState();
}

class _BusinessEnterprisePageState extends State<BusinessEnterprisePage> {
  Map<String, dynamic> overview = {}, readiness = {}, usage = {}, settings = {};
  List<dynamic> records = [], searchResults = [];
  bool loading = true, saving = false, searching = false;
  String typeFilter = 'all';
  String query = '';
  String? error;
  AppState get app => context.read<AppState>();
  String get base =>
      '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/enterprise';

  static const recordTypes = <String, String>{
    'handbook': 'Company handbook / procedure',
    'notification': 'Team notification',
    'approval': 'Approval request',
    'refund_case': 'Refund case',
    'credit_profile': 'Customer credit profile',
    'project_room': 'Customer project room',
    'supplier_quote': 'Supplier quotation',
    'service_policy': 'Service guarantee / policy',
    'delivery_proof': 'Delivery / collection proof',
    'dispute': 'Dispute resolution',
    'consent_record': 'Consent record',
    'support_case': 'Support / complaint case',
    'incident': 'Incident report',
    'integration': 'Integration record',
    'migration_job': 'Data import / migration',
    'recovery_plan': 'Recovery plan',
    'promise': 'Customer / supplier promise',
    'response_target': 'Response-time target',
    'subscription_note': 'Subscription / billing note',
    'financial_close': 'Financial period close',
    'supplier_comparison': 'Supplier comparison',
    'customer_portal': 'Customer self-service portal',
    'reputation_review': 'Transaction-linked review',
    'service_recovery': 'Service recovery plan',
  };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final results = await Future.wait([
        app.api.call('GET', '$base/overview'),
        app.api.call('GET', '$base/records?limit=100'),
        app.api.call('GET', '$base/readiness'),
        app.api.call('GET', '$base/usage'),
        app.api.call('GET', '$base/settings'),
      ]);
      overview = Map<String, dynamic>.from(results[0]);
      records = List<dynamic>.from(results[1]['records'] ?? []);
      readiness = Map<String, dynamic>.from(results[2]);
      usage = Map<String, dynamic>.from(results[3]);
      settings = Map<String, dynamic>.from(results[4]);
      if (mounted) setState(() {});
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<dynamic> get visibleRecords {
    final q = query.trim().toLowerCase();
    return records.where((item) {
      if (item is! Map) return false;
      if (typeFilter != 'all' && item['type'] != typeFilter) return false;
      if (q.isEmpty) return true;
      return '${item['title'] ?? ''} ${item['description'] ?? ''} ${item['status'] ?? ''}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  Future<void> searchAll() async {
    final q = query.trim();
    if (q.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Enter at least two characters to search all business records.')));
      }
      return;
    }
    setState(() => searching = true);
    try {
      final response = await app.api.call('GET',
          '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/search?q=${Uri.encodeQueryComponent(q)}');
      searchResults = List<dynamic>.from(response['results'] ?? []);
      if (mounted) setState(() {});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Search results for "$q"'),
          content: SizedBox(
            width: 480,
            child: searchResults.isEmpty
                ? const Text(
                    'No matching customers, products, invoices, tasks or enterprise records found in this workspace.')
                : ListView(
                    shrinkWrap: true,
                    children: searchResults
                        .map((item) => ListTile(
                              leading: const Icon(Icons.search),
                              title: Text(item['title']?.toString() ??
                                  'Business record'),
                              subtitle: Text(
                                  '${item['type'] ?? 'record'} · ${item['status'] ?? item['subtitle'] ?? ''}'),
                            ))
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'))
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> configureEnterpriseSettings() async {
    final targets = settings['serviceTargets'] is Map
        ? Map<String, dynamic>.from(settings['serviceTargets'])
        : <String, dynamic>{};
    final credit = settings['creditPolicy'] is Map
        ? Map<String, dynamic>.from(settings['creditPolicy'])
        : <String, dynamic>{};
    final firstResponse = TextEditingController(
        text: (targets['firstResponseMinutes'] ?? 15).toString());
    final escalation = TextEditingController(
        text: (targets['escalationMinutes'] ?? 60).toString());
    final terms = TextEditingController(
        text: (credit['defaultTermsDays'] ?? 0).toString());
    final threshold = TextEditingController(
        text: (credit['approvalRequiredAbove'] ?? 0).toString());
    final creditEnabled = ValueNotifier<bool>(credit['enabled'] == true);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Service and credit controls'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: firstResponse,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'First response target (minutes)')),
          TextField(
              controller: escalation,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Escalation target (minutes)')),
          const Divider(height: 24),
          ValueListenableBuilder<bool>(
              valueListenable: creditEnabled,
              builder: (_, value, __) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable customer credit policy'),
                    value: value,
                    onChanged: (next) => creditEnabled.value = next,
                  )),
          TextField(
              controller: terms,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Default payment terms (days, 0–365)')),
          TextField(
              controller: threshold,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText:
                      'Require approval above (amount, 0 disables threshold)')),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save controls')),
        ],
      ),
    );
    if (accepted != true) return;
    final first = int.tryParse(firstResponse.text) ?? 0;
    final escalate = int.tryParse(escalation.text) ?? 0;
    final termsDays = int.tryParse(terms.text) ?? -1;
    final approvalAmount = double.tryParse(threshold.text) ?? -1;
    if (first < 1 ||
        escalate < first ||
        termsDays < 0 ||
        termsDays > 365 ||
        approvalAmount < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Check the response targets, credit terms and approval threshold.')));
      }
      return;
    }
    setState(() => saving = true);
    try {
      await app.api.call('PATCH', '$base/settings', {
        'serviceTargets': {
          'firstResponseMinutes': first,
          'escalationMinutes': escalate
        },
        'creditPolicy': {
          'enabled': creditEnabled.value,
          'defaultTermsDays': termsDays,
          'approvalRequiredAbove': approvalAmount
        },
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Service and credit settings saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> downloadBusinessArchive() async {
    setState(() => saving = true);
    try {
      final token = app.api.token;
      if (token == null || token.isEmpty) {
        throw Exception('Sign in again before exporting business records.');
      }
      final orgId = Uri.encodeComponent(widget.organizationId);
      final uri =
          Uri.parse('${app.api.base}/api/business/organizations/$orgId/export');
      final response = await app.api.client.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json'
      });
      if (response.statusCode != 200) {
        throw Exception(
            'Business archive export failed with status ${response.statusCode}. Manager permissions may be required.');
      }
      await FileSaver.instance.saveFile(
        name: 'chatify-business-archive',
        bytes: response.bodyBytes,
        fileExtension: 'json',
        mimeType: MimeType.json,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Full business archive exported. Keep it in a secure location.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> downloadEnterpriseExport() async {
    setState(() => saving = true);
    try {
      final token = app.api.token;
      if (token == null || token.isEmpty) {
        throw Exception('Sign in again before exporting business records.');
      }
      final uri = Uri.parse('${app.api.base}$base/export');
      final response = await app.api.client.get(uri,
          headers: {'Authorization': 'Bearer $token', 'Accept': 'text/csv'});
      if (response.statusCode != 200) {
        throw Exception(
            'Export failed with status ${response.statusCode}. Check your finance or manager permissions.');
      }
      await FileSaver.instance.saveFile(
        name: 'chatify-business-records',
        bytes: response.bodyBytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Business records CSV exported.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> closeFinancialPeriod() async {
    final now = DateTime.now();
    final startDate = TextEditingController(
        text: DateTime(now.year, now.month, 1)
            .toIso8601String()
            .substring(0, 10));
    final endDate = TextEditingController(
        text: now
            .add(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10));
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close financial period'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Creates an immutable snapshot of invoices created between the start date and the exclusive end date.'),
          TextField(
              controller: startDate,
              decoration:
                  const InputDecoration(labelText: 'Start date (YYYY-MM-DD)')),
          TextField(
              controller: endDate,
              decoration: const InputDecoration(
                  labelText: 'End date, exclusive (YYYY-MM-DD)')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Close period')),
        ],
      ),
    );
    if (accepted != true) return;
    final start = DateTime.tryParse(startDate.text.trim());
    final end = DateTime.tryParse(endDate.text.trim());
    if (start == null || end == null || !start.isBefore(end)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Enter valid dates; the end date must be after the start date.')));
      }
      return;
    }
    setState(() => saving = true);
    try {
      final result =
          await app.api.call('POST', '$base/financial-periods/close', {
        'periodStart': '${startDate.text.trim()}T00:00:00.000Z',
        'periodEnd': '${endDate.text.trim()}T00:00:00.000Z',
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['notice']?.toString() ??
                'Financial period snapshot created.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> createRecord() async {
    final title = TextEditingController();
    final description = TextEditingController();
    final type = ValueNotifier<String>('handbook');
    final priority = ValueNotifier<String>('normal');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create enterprise record'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<String>(
              valueListenable: type,
              builder: (_, value, __) => DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: value,
                    decoration: const InputDecoration(labelText: 'Record type'),
                    items: recordTypes.entries
                        .where((entry) => entry.key != 'financial_close')
                        .map((entry) => DropdownMenuItem(
                            value: entry.key, child: Text(entry.value)))
                        .toList(),
                    onChanged: (next) {
                      if (next != null) type.value = next;
                    },
                  )),
          const SizedBox(height: 8),
          TextField(
              controller: title,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Title')),
          TextField(
              controller: description,
              maxLines: 3,
              maxLength: 6000,
              decoration: const InputDecoration(labelText: 'Details / reason')),
          ValueListenableBuilder<String>(
              valueListenable: priority,
              builder: (_, value, __) => DropdownButtonFormField<String>(
                    initialValue: value,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    items: const [
                      DropdownMenuItem(value: 'low', child: Text('Low')),
                      DropdownMenuItem(value: 'normal', child: Text('Normal')),
                      DropdownMenuItem(value: 'high', child: Text('High')),
                      DropdownMenuItem(value: 'urgent', child: Text('Urgent')),
                    ],
                    onChanged: (next) {
                      if (next != null) priority.value = next;
                    },
                  )),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (accepted != true || title.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      await app.api.call('POST', '$base/records', {
        'type': type.value,
        'title': title.text.trim(),
        'description': description.text.trim(),
        'priority': priority.value,
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enterprise record created.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> createCustomerShare(Map<String, dynamic> item) async {
    try {
      final result = await app.api.call('POST', '$base/shares', {
        'entityType': 'enterprise_record',
        'entityId': item['_id']?.toString() ?? '',
        'expiresInHours': 72,
      });
      final path = result['path']?.toString() ?? '';
      if (path.isEmpty || !mounted) return;
      final link = Uri.parse(app.api.base).resolve(path).toString();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Secure customer link'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'This link expires in 72 hours. Share it only with the intended customer.'),
                const SizedBox(height: 8),
                SelectableText(link),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Customer link copied.')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> runAction(Map<String, dynamic> item, String action) async {
    final id = Uri.encodeComponent(item['_id']?.toString() ?? '');
    if (id.isEmpty) return;
    try {
      if (action == 'acknowledge') {
        await app.api.call('POST', '$base/records/$id/acknowledge', {});
      } else if (action == 'approve' || action == 'reject') {
        final reason = TextEditingController();
        if (action == 'reject') {
          final accepted = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                    title: const Text('Reason for rejection'),
                    content: TextField(
                        controller: reason,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            labelText: 'Required reason')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Reject request')),
                    ],
                  ));
          if (accepted != true || reason.text.trim().isEmpty) return;
        }
        await app.api.call('POST', '$base/records/$id/decision', {
          'decision': action == 'approve' ? 'approved' : 'rejected',
          'reason': reason.text.trim()
        });
      } else {
        await app.api.call('POST', '$base/records/$id/resolve',
            {'resolution': 'Resolved from Chatify Business'});
      }
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = overview['counts'] is Map
        ? Map<String, dynamic>.from(overview['counts'])
        : <String, dynamic>{};
    final business = overview['business'] is Map
        ? Map<String, dynamic>.from(overview['business'])
        : <String, dynamic>{};
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.organizationName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Refresh enterprise workspace',
              onPressed: load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: saving ? null : createRecord,
        icon: const Icon(Icons.add),
        label: const Text('Add record'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: load, child: const Text('Retry')),
                      ])))
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      children: [
                        Text('Business command centre',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                            'Overview, accountability and follow-up records for this workspace. Sensitive actions are checked by the server.'),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          _enterpriseMetric('Customers',
                              business['customers'] ?? 0, Icons.people_outline),
                          _enterpriseMetric(
                              'Active products',
                              business['activeCatalogItems'] ?? 0,
                              Icons.inventory_2_outlined),
                          _enterpriseMetric('Open tasks',
                              business['openTasks'] ?? 0, Icons.task_alt),
                          _enterpriseMetric(
                              'Open cases',
                              business['openCases'] ?? 0,
                              Icons.support_agent_outlined),
                          _enterpriseMetric(
                              'Overdue records',
                              overview['overdueEnterpriseRecords'] ?? 0,
                              Icons.warning_amber_outlined),
                        ]),
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      'Setup readiness: ${readiness['complete'] ?? 0}/${readiness['total'] ?? 0}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 8),
                                  for (final check
                                      in (readiness['checks'] as List? ??
                                              const [])
                                          .whereType<Map>())
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(check['complete'] == true
                                          ? Icons.check_circle_outline
                                          : Icons.radio_button_unchecked),
                                      title: Text(check['label']?.toString() ??
                                          'Setup step'),
                                      trailing: Text(check['complete'] == true
                                          ? 'Ready'
                                          : 'Incomplete'),
                                    ),
                                ]),
                          ),
                        ),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Plan and usage',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  Text(
                                      'Plan: ${usage['plan'] ?? settings['plan'] ?? 'free'}'),
                                  Text(
                                      'Staff: ${(usage['usage'] as Map?)?['members'] ?? 1} · Customers: ${(usage['usage'] as Map?)?['customers'] ?? 0} · Catalogue items: ${(usage['usage'] as Map?)?['catalogItems'] ?? 0}'),
                                  Text(
                                      'Response target: ${(settings['serviceTargets'] as Map?)?['firstResponseMinutes'] ?? 15} minutes · Escalation: ${(settings['serviceTargets'] as Map?)?['escalationMinutes'] ?? 60} minutes'),
                                  Text(
                                      'Credit policy: ${(settings['creditPolicy'] as Map?)?['enabled'] == true ? 'Enabled' : 'Disabled'}'),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: saving
                                          ? null
                                          : configureEnterpriseSettings,
                                      icon: const Icon(Icons.tune),
                                      label: const Text(
                                          'Configure response and credit controls'),
                                    ),
                                  ),
                                ]),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text('Enterprise modules',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final entry in recordTypes.entries)
                            Chip(
                                avatar: const Icon(Icons.checklist, size: 16),
                                label: Text(
                                    '${entry.value}: ${counts[entry.key] ?? 0}')),
                        ]),
                        const SizedBox(height: 16),
                        TextField(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            labelText: 'Search business records',
                            helperText:
                                'Type to filter this list, or use the search icon for customers, products, invoices, tasks and cases.',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: 'Search all business data',
                              onPressed: searching ? null : searchAll,
                              icon: searching
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.manage_search),
                            ),
                          ),
                          onChanged: (value) => setState(() => query = value),
                          onSubmitted: (_) => searchAll(),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: typeFilter,
                          decoration: const InputDecoration(
                              labelText: 'Filter by module',
                              border: OutlineInputBorder()),
                          items: [
                            const DropdownMenuItem(
                                value: 'all',
                                child: Text('All enterprise records')),
                            ...recordTypes.entries.map((entry) =>
                                DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value))),
                          ],
                          onChanged: (value) =>
                              setState(() => typeFilter = value ?? 'all'),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                              child: Text('Records (${visibleRecords.length})',
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          TextButton.icon(
                            onPressed: saving ? null : downloadEnterpriseExport,
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('Export CSV'),
                          ),
                        ]),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: saving ? null : closeFinancialPeriod,
                            icon: const Icon(Icons.lock_clock_outlined),
                            label: const Text('Close financial period'),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: saving ? null : downloadBusinessArchive,
                            icon: const Icon(Icons.backup_outlined),
                            label: const Text(
                                'Export full business archive (JSON)'),
                          ),
                        ),
                        if (visibleRecords.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                  'No matching records yet. Add a handbook, approval request, project room, promise, support case or other enterprise record.',
                                  textAlign: TextAlign.center)),
                        for (final item in visibleRecords.whereType<Map>())
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: CircleAvatar(
                                          child: Icon(item['priority'] ==
                                                  'urgent'
                                              ? Icons.priority_high
                                              : Icons
                                                  .business_center_outlined)),
                                      title: Text(item['title']?.toString() ??
                                          'Business record'),
                                      subtitle: Text(
                                          _enterpriseRecordSubtitle(
                                              Map<String, dynamic>.from(item)),
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                    Wrap(spacing: 8, children: [
                                      if (item['type'] == 'handbook' ||
                                          item['type'] == 'service_policy')
                                        OutlinedButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'acknowledge'),
                                            icon: const Icon(
                                                Icons.fact_check_outlined),
                                            label: const Text('Acknowledge')),
                                      if ([
                                        'project_room',
                                        'customer_portal',
                                        'service_policy',
                                        'delivery_proof'
                                      ].contains(item['type']))
                                        OutlinedButton.icon(
                                          onPressed: () => createCustomerShare(
                                              Map<String, dynamic>.from(item)),
                                          icon: const Icon(Icons.link),
                                          label:
                                              const Text('Share with customer'),
                                        ),
                                      if (item['status'] == 'pending' &&
                                          [
                                            'approval',
                                            'refund_case',
                                            'credit_profile',
                                            'dispute'
                                          ].contains(item['type'])) ...[
                                        OutlinedButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'reject'),
                                            icon: const Icon(Icons.close),
                                            label: const Text('Reject')),
                                        FilledButton.tonalIcon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'approve'),
                                            icon: const Icon(Icons.check),
                                            label: const Text('Approve')),
                                      ],
                                      if (![
                                        'closed',
                                        'cancelled',
                                        'resolved',
                                        'approved',
                                        'rejected'
                                      ].contains(item['status']))
                                        TextButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'resolve'),
                                            icon: const Icon(Icons.done_all),
                                            label: const Text('Resolve')),
                                    ]),
                                  ]),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Text('Payment and security reminder',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Text(
                            'A payment screenshot, manually typed reference or accepted checkout request is not proof of receipt. Only verified provider callbacks or authorized reconciliation can confirm money received.'),
                      ]),
                ),
    );
  }

  String _enterpriseRecordSubtitle(Map<String, dynamic> item) {
    final type = item['type']?.toString() ?? '';
    final status = item['status']?.toString() ?? 'open';
    final priority = item['priority']?.toString() ?? 'normal';
    final description = item['description']?.toString() ?? '';
    if (type == 'financial_close' && item['payload'] is Map) {
      final payload = Map<String, dynamic>.from(item['payload'] as Map);
      final org = overview['organization'] is Map
          ? Map<String, dynamic>.from(overview['organization'])
          : <String, dynamic>{};
      final currency = org['currency']?.toString() ?? 'KES';
      return 'Closed snapshot · ${payload['invoiceCount'] ?? 0} invoices\n'
          'Invoiced: $currency ${payload['invoicedTotal'] ?? 0} · Verified receipts in period: $currency ${payload['confirmedPaidTotal'] ?? 0}\n'
          'Outstanding at period end: $currency ${payload['outstandingTotal'] ?? 0}';
    }
    return '${recordTypes[type] ?? type} · $status · $priority\n$description';
  }

  Widget _enterpriseMetric(String label, dynamic value, IconData icon) =>
      SizedBox(
        width: 150,
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(icon, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(value.toString(),
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(label,
                            style: Theme.of(context).textTheme.bodySmall),
                      ])),
                ]))),
      );
}
